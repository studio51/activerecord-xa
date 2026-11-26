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
    ensure
      @branches.each { |b| b.connection.active_xa_branch = nil }
      @discard.each { |c| discard_connection(c) }
    end

    private
      def nest(remaining, &block)
        return block.call if remaining.empty?

        pool, index = remaining.first
        connection = pool.lease_connection
        if connection.transaction_open?
          raise TransactionAlreadyOpen,
                "#{pool.db_config.name} already has an open transaction; ActiveXA must open the outermost one"
        end

        branch = Branch.new(connection, Xid.new(@gtrid, bqual_for(pool, index)))
        connection.active_xa_branch = branch
        @branches << branch

        connection.transaction do
          branch.ar_transaction = connection.current_transaction
          nest(remaining.drop(1), &block)
        end
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
        @branches.each { |b| b.ar_transaction.active_xa_run_before_commit! }

        active = @branches.select(&:started?)
        case active.size
        when 0 then nil
        when 1 then commit_one_phase(active.first)
        else two_phase_commit(active)
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

      def bqual_for(pool, index)
        "#{index}-#{pool.db_config.name}"[0, 64]
      end

      def discard_connection(connection)
        connection.disconnect!
      rescue => e
        @config.logger&.warn("ActiveXA: error discarding connection: #{e.message}")
      end
  end
end
