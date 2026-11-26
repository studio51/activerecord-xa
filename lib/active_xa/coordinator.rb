# frozen_string_literal: true

module ActiveXA

  # Runs one global transaction.
  #
  # 1. Opens a normal Rails transaction on each participant, nested, with the connection enlisted so Rails' BEGIN becomes XA START.
  # 2. Runs the block.
  # 3. Inside the innermost Rails transaction, before any of them exits: runs before_commit callbacks, XA PREPAREs every branch, logs the commit decision, then XA COMMITs every branch.
  # 4. Lets the Rails blocks exit. Their COMMITs are no-ops.
  # 5. Runs after_commit callbacks, once the data is durable everywhere and every connection is an ordinary one again.
  #
  # Any failure before the decision is logged rolls back every branch.
  # From the moment the decision may be in the log, nothing here rolls a branch back: what could not be committed is left in doubt for recovery.
  #
  class Coordinator
    attr_reader :gtrid # the global transaction id shared by every branch

    # Prepares a transaction over the given participants.
    #
    # @param record_classes [Array<Class>] Active Record classes, one or more per participating database
    # @param log [DecisionLog] where the commit decision is written
    # @param config [Configuration] settings for logging and notification
    # @raise [ArgumentError] unless the classes span at least two databases
    # @return [Coordinator] the new coordinator
    def initialize(record_classes, log:, config: ActiveXA.config)
      @pools = record_classes.map(&:connection_pool).uniq
      @log = log
      @config = config
      @gtrid = Xid.generate_gtrid(log.namespace)
      @branches = []
      @rollback_requested = false
      @outcome = :rolled_back

      if @pools.size < 2
        raise ArgumentError, "ActiveXA.transaction needs classes on at least two different databases"
      end
    end

    # Runs the block inside the global transaction and commits or rolls back every database together.
    #
    # @yield the work to do, using models as normal
    # @return [Object] the block's value, or nil when it raised ActiveRecord::Rollback
    def run(&block)
      result = nil
      nest(@pools.each_with_index.to_a) { result = run_block(&block) }

      result
    ensure
      release_callbacks
    end

    private

      # --- Opening the participants' transactions ---

      # Opens the participants' transactions one inside the other.
      # Each connection is borrowed only while its transaction is open: with_connection reuses one the caller already holds, and otherwise hands it back to the pool afterwards, as Model.transaction does.
      #
      # @param remaining [Array<Array(ActiveRecord::ConnectionAdapters::ConnectionPool, Integer)>] pools still to open, with their positions
      # @yield the block to run inside the innermost transaction
      # @return [Object] the block's value
      def nest(remaining, &block)
        return block.call if remaining.empty?

        pool, index = remaining.first

        pool.with_connection do |connection|
          if connection.transaction_open?
            raise TransactionAlreadyOpen,
                  "#{ pool.db_config.name } already has an open transaction; ActiveXA must open the outermost one"
          end

          enlist(connection, Xid.new(@gtrid, Xid.bqual(index, pool.db_config.name))) do
            nest(remaining.drop(1), &block)
          end
        end
      end

      # Enlists a connection in the global transaction and opens its Rails transaction.
      # The default isolation level is applied the way Model.transaction applies it; with that default set, Rails refuses every save inside a transaction opened without it.
      # Before the connection can reach anyone else through the pool it is de-enlisted, and closed if its branch was left for recovery, so the server lets go of it.
      #
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter] the participant's connection
      # @param xid [Xid] the branch's XID
      # @yield runs inside the participant's transaction
      # @return [Object] the block's value
      def enlist(connection, xid)
        branch = Branch.new(connection, xid)
        @branches << branch
        connection.active_xa_branch = branch
        default_isolation = ActiveRecord.default_transaction_isolation_level

        connection.pool.with_pool_transaction_isolation_level(default_isolation, false) do
          connection.transaction do
            branch.ar_transaction = connection.current_transaction
            branch.ar_transaction.active_xa_hold_callbacks!
            yield
            # Rails swallows ActiveRecord::Rollback where the innermost transaction ends.
            # Every participant has to roll back, so each level raises it again for the one outside it.
            #
            raise ActiveRecord::Rollback if @rollback_requested
          end
        end
      ensure
        connection.active_xa_branch = nil
        discard_connection(connection) if branch&.in_doubt?
      end

      # Runs the block and commits as Rails would.
      # Rails commits when a transaction block exits early via return, break or throw, and rolls back when the block raises or its thread is being killed.
      #
      # @yield the caller's block
      # @return [Object] the block's value
      def run_block
        outcome = :left_early
        result = yield
        outcome = :finished
        finish!

        result
      rescue Exception => e
        outcome = :raised
        @rollback_requested = e.is_a?(ActiveRecord::Rollback)

        raise
      ensure
        finish! if outcome == :left_early && Thread.current.status != "aborting"
      end

      # --- Committing ---

      # Runs before_commit callbacks, then commits the branches that started, in one phase or two.
      #
      # @return [void]
      def finish!
        run_before_commit_callbacks
        active = @branches.select(&:started?)

        case active.size
        when 0 then @outcome = :committed
        when 1 then commit_one_phase(active.first)
        else two_phase_commit(active)
        end
      end

      # Runs before_commit callbacks while every branch is still open, because they may write, possibly to another database.
      # The order is the one nested Rails transactions give: innermost first.
      # A callback can enrol records in a branch that has already had its turn, and Rails would give those a before_commit of their own, so the branch gets another pass.
      # A branch still in the middle of a pass does not, which is what Rails does too and is what keeps this finite.
      #
      # @return [void]
      def run_before_commit_callbacks
        finished = []

        @branches.reverse_each do |branch|
          before_commit_pass(branch, finished, [ branch ])
          finished << branch
        end
      end

      # Runs one branch's pass, visiting any finished branch that gained records while it ran.
      #
      # @param branch [Branch] the branch whose pass this is
      # @param finished [Array<Branch>] branches that have had their first pass
      # @param in_progress [Array<Branch>] branches whose pass is running, which are never revisited
      # @return [void]
      def before_commit_pass(branch, finished, in_progress)
        branch.ar_transaction.active_xa_run_before_commit! do
          (finished - in_progress).each do |other|
            next unless other.ar_transaction.active_xa_before_commit_pending?

            before_commit_pass(other, finished, in_progress + [ other ])
          end
        end
      end

      # Commits the only branch that started, with no prepare and no log.
      #
      # @param branch [Branch] the branch
      # @raise [PrepareFailed] if the commit fails
      # @return [void]
      def commit_one_phase(branch)
        @outcome = :unknown
        branch.commit_one_phase!

        @outcome = :committed
      rescue => e
        rollback_all([ branch ])
        # If the rollback failed as well, the commit may have gone through after all, and the outcome stays unknown.
        #
        @outcome = :rolled_back if branch.state == :rolled_back

        raise PrepareFailed, "one-phase commit failed on #{ branch.xid }: #{ e.message }"
      end

      # Prepares every branch, logs the decision, then commits every branch.
      # Once the decision is durable the transaction is committed, so a failed XA COMMIT is reported rather than raised: the caller retrying would duplicate work.
      #
      # @param active [Array<Branch>] the branches that started
      # @raise [PrepareFailed] if a branch fails to prepare
      # @return [void]
      def two_phase_commit(active)
        begin
          active.each(&:end_and_prepare!)
        rescue => e
          rollback_all(active)

          raise PrepareFailed, "prepare failed: #{ e.message }"
        end

        log_commit_decision(active)

        failures = active.filter_map do |branch|
          branch.commit!

          nil
        rescue => e
          [ branch, e ]
        end

        if failures.empty?
          complete_log
        else
          report_incomplete(failures)
        end
      end

      # --- The decision ---

      # Logs the commit decision.
      # Once the insert has been sent the decision may be durable, whatever happens to this process next, so the branches stop being ours to roll back first.
      # An exception or a killed thread from here on leaves them prepared for recovery instead of undoing half a committed transaction.
      #
      # @param active [Array<Branch>] the prepared branches
      # @raise [DecisionLogFailed] if the decision did not stand and everything was rolled back
      # @raise [OutcomeUnknown] if the log could not say what was decided
      # @return [void]
      def log_commit_decision(active)
        @outcome = :unknown
        active.each(&:mark_in_doubt!)
        @log.record_commit!(@gtrid, active.map { |branch| branch.connection.pool.db_config.name })

        @outcome = :committed
      rescue ActiveRecord::ConnectionNotEstablished => e
        # No connection to the log could be had (it is down, or its pool is exhausted), so the insert was never sent and nothing is in doubt.
        #
        abandon_commit(active, e)
      rescue => e
        settle_failed_decision(active, e)
      end

      # Lets the log settle a failed insert.
      # An insert that was sent and failed proves nothing: the row can be written and its acknowledgement lost, or recovery may have decided first.
      # We ask for "abort", which the primary key refuses if the commit row is there, and go with whichever decision stands.
      #
      # @param active [Array<Branch>] the prepared branches
      # @param error [Exception] why the insert failed
      # @raise [DecisionLogFailed] if the decision is abort
      # @raise [OutcomeUnknown] if the log cannot be asked
      # @return [void]
      def settle_failed_decision(active, error)
        standing = begin
          @log.settle!(@gtrid)
        rescue => e
          raise OutcomeUnknown, "could not log the commit decision for #{ @gtrid } (#{ error.message }) " \
                                "or find out whether it was logged (#{ e.message }); recovery will finish the transaction"
        end

        if standing == :commit
          @outcome = :committed
        else
          abandon_commit(active, error)
        end
      end

      # Rolls every branch back after the decision failed to stand.
      #
      # @param active [Array<Branch>] the prepared branches
      # @param error [Exception] why the decision failed
      # @raise [DecisionLogFailed] always
      # @return [void]
      def abandon_commit(active, error)
        active.each(&:release_from_doubt!)
        rollback_all(active)
        @outcome = :rolled_back

        raise DecisionLogFailed, decision_failure_message(error)
      end

      # Explains why the decision did not stand.
      #
      # @param error [Exception] why the decision failed
      # @return [String] the message
      def decision_failure_message(error)
        if error.is_a?(ActiveRecord::RecordNotUnique)
          "recovery rolled #{ @gtrid } back before its commit decision was logged; " \
            "the transaction ran for longer than recovery_grace_period"
        else
          "could not log commit decision for #{ @gtrid }: #{ error.message }"
        end
      end

      # --- Cleaning up ---

      # Rolls the given branches back, leaving any that fail to recovery.
      # With no commit decision in the log, recovery rolls them back (presumed abort).
      # Marking them stops Rails trying again as the blocks unwind, which would only bury the error that brought us here.
      #
      # @param branches [Array<Branch>] the branches
      # @return [void]
      def rollback_all(branches)
        branches.each do |branch|
          branch.rollback!
        rescue => e
          @config.logger&.error("ActiveXA: could not roll back #{ branch.xid }, leaving it to recovery: #{ e.message }")
          branch.mark_in_doubt!
        end
      end

      # Deletes the decision once every branch has committed.
      # A failure is harmless: recovery prunes decisions with no prepared branches left.
      #
      # @return [void]
      def complete_log
        @log.complete!(@gtrid)
      rescue => e
        @config.logger&.warn("ActiveXA: could not clear decision #{ @gtrid }: #{ e.message }")
      end

      # Reports branches that are committed by decision but failed to apply XA COMMIT.
      # The transaction is committed, so a notifier that fails must not make it look otherwise to the caller.
      #
      # @param failures [Array<Array(Branch, Exception)>] the branches and their errors
      # @return [void]
      def report_incomplete(failures)
        details = failures.map { |b, e| "#{ b.xid }: #{ e.class }: #{ e.message }" }.join("; ")
        @config.logger&.error("ActiveXA: #{ @gtrid } committed but not yet applied everywhere: #{ details }")

        @config.on_incomplete_commit&.call(@gtrid, failures)
      rescue => e
        @config.logger&.error("ActiveXA: on_incomplete_commit raised #{ e.class }: #{ e.message }")
      end

      # Runs after_commit or after_rollback callbacks, innermost transaction first as Rails would.
      # Which of the two follows how the global transaction ended, not how each Rails block happened to exit; when the outcome is not known, neither runs.
      # By now every participant's transaction has closed, so a callback can use any of the databases, or start another ActiveXA transaction.
      # One database's callbacks failing does not cost the others theirs; the first error is raised once all have run.
      #
      # @return [void]
      def release_callbacks
        action = { committed: :commit_records, rolled_back: :rollback_records }[@outcome]
        error = nil

        @branches.reverse_each do |branch|
          branch.ar_transaction&.active_xa_release_callbacks!(action)
        rescue => e
          error ||= e
        end

        raise error if error
      end

      # Closes a connection that may still hold a prepared branch, so the server detaches it.
      #
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter] the connection
      # @return [void]
      def discard_connection(connection)
        connection.disconnect!
      rescue => e
        @config.logger&.warn("ActiveXA: error discarding connection: #{ e.message }")
      end
  end
end
