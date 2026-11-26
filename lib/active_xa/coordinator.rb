# frozen_string_literal: true

module ActiveXA
  # Runs one global transaction:
  #
  # 1. Opens a normal Rails transaction on each participant, nested, with
  #    the connection enlisted so Rails' BEGIN becomes XA START.
  # 2. Runs the block.
  # 3. Inside the innermost Rails transaction, before any of them exits:
  #    runs before_commit callbacks, XA PREPAREs every branch, logs the
  #    commit decision, then XA COMMITs every branch.
  # 4. Lets the Rails blocks exit. Their COMMITs are no-ops, so after_commit
  #    callbacks fire only once the data is durable everywhere.
  #
  # Any failure before the decision is logged rolls back every branch.
  # Failures after it leave branches :in_doubt for recovery to commit.
  class Coordinator
    def initialize(record_classes, log:, config: ActiveXA.config)
      @pools = record_classes.map(&:connection_pool).uniq
      @log = log
      @config = config
      @gtrid = Xid.generate_gtrid
      @branches = []
      @discard = []

      if @pools.size < 2
        raise ArgumentError, "ActiveXA.transaction needs classes on at least two different databases"
      end
    end

    attr_reader :gtrid

    def run(&block)
      result = nil
      nest(@pools.each_with_index.to_a) { result = run_block(&block) }
      result
    end

    private
      # Opens the participants' transactions one inside the other. Each
      # connection is borrowed only while its transaction is open:
      # with_connection reuses one the caller already holds, and otherwise
      # hands it back to the pool afterwards, as Model.transaction does.
      def nest(remaining, &block)
        return block.call if remaining.empty?

        pool, index = remaining.first
        pool.with_connection do |connection|
          if connection.transaction_open?
            raise TransactionAlreadyOpen,
                  "#{pool.db_config.name} already has an open transaction; ActiveXA must open the outermost one"
          end

          enlist(connection, Xid.new(@gtrid, Xid.bqual(index, pool.db_config.name))) do
            nest(remaining.drop(1), &block)
          end
        end
      end

      def enlist(connection, xid)
        branch = Branch.new(connection, xid)
        @branches << branch
        connection.active_xa_branch = branch

        connection.transaction do
          branch.ar_transaction = connection.current_transaction
          yield
        end
      ensure
        # Before the connection can reach anyone else through the pool.
        connection.active_xa_branch = nil
        discard_connection(connection) if @discard.include?(connection)
      end

      # Rails commits when a transaction block exits early via return, break
      # or throw, so we do too. Exceptions skip finish! and roll back.
      def run_block
        completed = false
        result = yield
        completed = true
        finish!
        result
      ensure
        finish! if !completed && $!.nil?
      end

      def finish!
        run_before_commit_callbacks

        active = @branches.select(&:started?)
        case active.size
        when 0 then nil
        when 1 then commit_one_phase(active.first)
        else two_phase_commit(active)
        end
      end

      # before_commit callbacks run while every branch is still open, because
      # they may write (deferred touches do), possibly to another database.
      # The order is the one nested Rails transactions give: innermost first.
      #
      # A callback can enrol records in a branch that has already had its
      # turn. Rails would treat that as a new transaction with a before_commit
      # of its own, so the branch gets another pass. A branch still in the
      # middle of a pass does not, which is what Rails does too and is what
      # keeps this finite.
      def run_before_commit_callbacks
        finished = []
        @branches.reverse_each do |branch|
          before_commit_pass(branch, finished, [branch])
          finished << branch
        end
      end

      def before_commit_pass(branch, finished, in_progress)
        branch.ar_transaction.active_xa_run_before_commit! do
          (finished - in_progress).each do |other|
            next unless other.ar_transaction.active_xa_before_commit_pending?

            before_commit_pass(other, finished, in_progress + [other])
          end
        end
      end

      def commit_one_phase(branch)
        branch.commit_one_phase!
      rescue => e
        rollback_all([branch])
        raise PrepareFailed, "one-phase commit failed on #{branch.xid}: #{e.message}"
      end

      def two_phase_commit(active)
        begin
          active.each(&:end_and_prepare!)
        rescue => e
          rollback_all(active)
          raise PrepareFailed, "prepare failed: #{e.message}"
        end

        begin
          @log.record_commit!(@gtrid, active)
        rescue => e
          rollback_all(active)
          raise DecisionLogFailed, "could not log commit decision for #{@gtrid}: #{e.message}"
        end

        # The decision is durable: from here the transaction IS committed.
        # Failures are not raised, since the caller retrying would duplicate
        # work. They're reported and left for recovery.
        failures = active.filter_map do |branch|
          branch.commit!
          nil
        rescue => e
          branch.mark_in_doubt!
          # A session holding a prepared branch can't run other statements,
          # and the branch can only be committed elsewhere once it detaches.
          @discard << branch.connection
          [branch, e]
        end

        if failures.empty?
          complete_log
        else
          report_incomplete(failures)
        end
      end

      def rollback_all(branches)
        branches.each do |branch|
          branch.rollback!
        rescue => e
          # Presumed abort: with no decision logged, recovery rolls it back.
          @config.logger&.error("ActiveXA: rollback of #{branch.xid} failed, recovery will retry: #{e.message}")
          @discard << branch.connection
        end
      end

      def complete_log
        @log.complete!(@gtrid)
      rescue => e
        # Harmless: recovery prunes decisions with no prepared branches left.
        @config.logger&.warn("ActiveXA: could not clear decision #{@gtrid}: #{e.message}")
      end

      def report_incomplete(failures)
        details = failures.map { |b, e| "#{b.xid}: #{e.class}: #{e.message}" }.join("; ")
        @config.logger&.error("ActiveXA: #{@gtrid} committed but not yet applied everywhere: #{details}")
        @config.on_incomplete_commit&.call(@gtrid, failures)
      end

      def discard_connection(connection)
        connection.disconnect!
      rescue => e
        @config.logger&.warn("ActiveXA: error discarding connection: #{e.message}")
      end
  end
end
