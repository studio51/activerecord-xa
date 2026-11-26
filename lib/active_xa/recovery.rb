# frozen_string_literal: true

module ActiveXA
  # Resolves branches left PREPARED by a crash or a failed commit:
  #
  # * "commit" logged  -> XA COMMIT
  # * no decision      -> log "abort", then XA ROLLBACK (presumed abort)
  #
  # XIDs younger than the grace period are left alone, so recovery does not
  # disturb a coordinator that is simply mid-commit. That is a courtesy, not
  # what keeps the two from disagreeing: a transaction can outlive the grace
  # period, which is measured from when it started. The abort marker is what
  # makes it safe. It takes the gtrid's place in the log, so a coordinator
  # that is still alive finds it cannot log "commit" and rolls back too.
  #
  # Needs the XA_RECOVER_ADMIN privilege on each database.
  #
  # XA RECOVER lists every prepared XID on the *server*, not just the
  # database the connection points at, so participants sharing a server see
  # each other's branches. XIDs are de-duplicated; any connection to the
  # right server can resolve a detached branch.
  #
  # It also lists the branches of anyone else using that server. Only XIDs
  # carrying this decision log's namespace are touched: another
  # installation's transactions are decided in its own log, and having no
  # decision for them here says nothing about what it decided.
  class Recovery
    # errors holds [subject, exception] pairs. The subject is the Xid that
    # could not be resolved, the name of a database that could not be asked,
    # or :prune.
    Report = Struct.new(:committed, :rolled_back, :skipped, :pruned, :errors) do
      def initialize = super([], [], [], [], [])
    end

    def initialize(record_classes, log:, grace:, abort_retention: ActiveXA.config.abort_retention)
      @pools = record_classes.map(&:connection_pool).uniq
      @log = log
      @grace = grace
      @abort_retention = abort_retention
    end

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
        # A database that is down, or whose user lacks XA_RECOVER_ADMIN, must
        # not keep the branches on the others waiting.
        report.errors << [pool.db_config.name, e]
        complete = false
      end

      # Without an answer from every database there is no telling which
      # decisions are finished, so nothing is pruned on this run.
      if complete
        outstanding = (report.skipped + report.errors.map(&:first).grep(Xid)).map(&:gtrid)
        prune_log(started, outstanding.uniq, report)
      end
      report
    end

    private
      def resolve(connection, xid, report)
        unless old_enough?(xid.gtrid)
          report.skipped << xid
          return
        end

        case outcome_of(xid.gtrid)
        when :commit
          connection.execute("XA COMMIT #{xid.to_sql(connection)}")
          report.committed << xid
        when :abort
          connection.execute("XA ROLLBACK #{xid.to_sql(connection)}")
          report.rolled_back << xid
        end
      rescue => e
        report.errors << [xid, e]
      end

      # Settled once per run, so every branch of a transaction gets the same
      # answer. With nothing in the log the answer is "abort", and it is
      # written down before anything is rolled back.
      def outcome_of(gtrid)
        @outcomes[gtrid] ||= @log.outcome(gtrid) || @log.settle!(gtrid)
      end

      # A decision with no branch still outstanding is finished and its row
      # can go, once it is old enough.
      #
      # For a commit that is the grace period, counted from when the row was
      # written. A row that old was there before this run looked for prepared
      # branches, so any that were still waiting have just been committed
      # above, or are outstanding.
      #
      # An abort marker stays for abort_retention, in case the coordinator it
      # stopped is still alive and about to try its commit.
      def prune_log(started, outstanding_gtrids, report)
        @log.expired(started, commit_age: @grace, abort_age: @abort_retention).each do |gtrid|
          next if outstanding_gtrids.include?(gtrid)

          @log.complete!(gtrid)
          report.pruned << gtrid
        end
      rescue => e
        report.errors << [:prune, e]
      end

      def prepared_xids(connection)
        rows = connection.uncached { connection.select_rows("XA RECOVER") }
        rows.filter_map do |format_id, gtrid_length, bqual_length, data|
          next unless Integer(format_id) == Xid::FORMAT_ID

          # The lengths count bytes, and data is not always single-byte.
          gl = Integer(gtrid_length)
          xid = Xid.new(data.byteslice(0, gl), data.byteslice(gl, Integer(bqual_length)))
          xid if Xid.namespace(xid.gtrid) == @log.namespace
        end
      end

      def old_enough?(gtrid)
        Time.now - Xid.created_at(gtrid) >= @grace
      end

      def with_connection(pool)
        connection = pool.checkout
        yield connection
      ensure
        pool.checkin(connection) if connection
      end
  end
end
