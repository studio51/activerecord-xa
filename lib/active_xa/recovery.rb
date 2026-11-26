# frozen_string_literal: true

module ActiveXA

  # Resolves branches left PREPARED by a crash or a failed commit.
  #
  # * "commit" logged: XA COMMIT
  # * no decision: log "abort", then XA ROLLBACK (presumed abort)
  #
  # XIDs younger than the grace period are left alone, so recovery does not disturb a coordinator that is simply mid-commit.
  # That is a courtesy, not what keeps the two from disagreeing: a transaction can outlive the grace period, which is measured from when it started.
  # The abort marker is what makes it safe: it takes the gtrid's place in the log, so a coordinator that is still alive finds it cannot log "commit" and rolls back too.
  #
  # XA RECOVER lists every prepared XID on the server, not just the database the connection points at, so participants sharing a server see each other's branches.
  # XIDs are de-duplicated, and any connection to the right server can resolve a detached branch.
  # It also lists the branches of anyone else using that server, so only XIDs carrying this decision log's namespace are touched.
  #
  # Needs the XA_RECOVER_ADMIN privilege on each database.
  #
  class Recovery

    # What a recovery run did.
    # Each list holds Xids, except pruned, which holds gtrids, and errors, which holds [subject, exception] pairs.
    # The subject of an error is the Xid that could not be resolved, the name of a database that could not be asked, or :prune.
    #
    Report = Struct.new(:committed, :rolled_back, :skipped, :pruned, :errors) do
      # Creates an empty report.
      #
      # @return [Report] the report
      def initialize = super([], [], [], [], [])
    end

    # Prepares a recovery run.
    #
    # @param record_classes [Array<Class>] Active Record classes covering every database that takes part in ActiveXA transactions
    # @param log [DecisionLog] the decision log
    # @param grace [Numeric] seconds a transaction must have been running before recovery touches it
    # @param abort_retention [Numeric] seconds to keep an abort marker
    # @return [Recovery] the new run
    def initialize(record_classes, log:, grace:, abort_retention: ActiveXA.config.abort_retention)
      @pools = record_classes.map(&:connection_pool).uniq
      @log = log
      @grace = grace
      @abort_retention = abort_retention
    end

    # Resolves every prepared branch old enough to touch, then prunes finished decisions.
    # A database that is down, or whose user lacks XA_RECOVER_ADMIN, is reported and does not keep the others waiting.
    # Without an answer from every database there is no telling which decisions are finished, so nothing is pruned on such a run.
    #
    # @return [Report] what the run did
    def run
      report = Report.new
      started = @log.now
      @outcomes = {}
      handled = {}
      complete = true

      @pools.each do |pool|
        with_connection(pool) do |connection|
          prepared_xids(connection).each do |xid|
            next if handled[xid.to_s]

            handled[xid.to_s] = true
            resolve(connection, xid, report)
          end
        end
      rescue => e
        report.errors << [ pool.db_config.name, e ]
        complete = false
      end

      if complete
        outstanding = (report.skipped + report.errors.map(&:first).grep(Xid)).map(&:gtrid)
        prune_log(started, outstanding.uniq, report)
      end

      report
    end

    private

      # Commits or rolls back one branch, as the log says.
      #
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter] a connection to the branch's server
      # @param xid [Xid] the branch
      # @param report [Report] where the result goes
      # @return [void]
      def resolve(connection, xid, report)
        unless old_enough?(xid.gtrid)
          report.skipped << xid

          return
        end

        case outcome_of(xid.gtrid)
        when :commit
          connection.execute("XA COMMIT #{ xid.to_sql(connection) }")
          report.committed << xid
        when :abort
          connection.execute("XA ROLLBACK #{ xid.to_sql(connection) }")
          report.rolled_back << xid
        end
      rescue => e
        report.errors << [ xid, e ]
      end

      # Reads a transaction's decision, deciding abort when there is none.
      # It is settled once per run, so every branch of a transaction gets the same answer, and the abort is written down before anything is rolled back.
      #
      # @param gtrid [String] the transaction's gtrid
      # @return [Symbol] :commit or :abort
      def outcome_of(gtrid)
        @outcomes[gtrid] ||= @log.outcome(gtrid) || @log.settle!(gtrid)
      end

      # Deletes decisions that are finished and old enough.
      # A commit decision waits the grace period, counted from when its row was written: a row that old was there before this run looked for prepared branches, so any still waiting were just committed above, or are outstanding.
      # An abort marker stays for abort_retention, in case the coordinator it stopped is still alive and about to try its commit.
      # Either way, only a run that was given every database a transaction used has seen all its branches.
      #
      # @param started [String] when this run started, on the log database's clock
      # @param outstanding_gtrids [Array<String>] transactions with a branch still waiting
      # @param report [Report] where the result goes
      # @return [void]
      def prune_log(started, outstanding_gtrids, report)
        covered = @pools.map { |pool| pool.db_config.name }

        @log.expired(started, commit_age: @grace, abort_age: @abort_retention).each do |gtrid, participants|
          next if outstanding_gtrids.include?(gtrid)
          next unless (participants - covered).empty?

          @log.complete!(gtrid)
          report.pruned << gtrid
        end
      rescue => e
        report.errors << [ :prune, e ]
      end

      # Lists this installation's prepared branches on a server.
      # The length columns of XA RECOVER count bytes, and the data is not always single-byte.
      #
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter] a connection to the server
      # @return [Array<Xid>] the branches
      def prepared_xids(connection)
        rows = connection.uncached { connection.select_rows("XA RECOVER") }

        rows.filter_map do |format_id, gtrid_length, bqual_length, data|
          next unless Integer(format_id) == Xid::FORMAT_ID

          gl = Integer(gtrid_length)
          xid = Xid.new(data.byteslice(0, gl), data.byteslice(gl, Integer(bqual_length)))

          xid if Xid.namespace(xid.gtrid) == @log.namespace
        end
      end

      # Whether a transaction has been running for longer than the grace period.
      #
      # @param gtrid [String] the transaction's gtrid
      # @return [Boolean] true if recovery may touch it
      def old_enough?(gtrid)
        Time.now - Xid.created_at(gtrid) >= @grace
      end

      # Checks out a connection of its own for one database.
      #
      # @param pool [ActiveRecord::ConnectionAdapters::ConnectionPool] the database's pool
      # @yieldparam connection [ActiveRecord::ConnectionAdapters::AbstractAdapter] the connection
      # @return [Object] the block's value
      def with_connection(pool)
        connection = pool.checkout
        yield connection
      ensure
        pool.checkin(connection) if connection
      end
  end
end
