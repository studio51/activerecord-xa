# frozen_string_literal: true

module ActiveRecord::XA

  # Prepended to Active Record's transaction class.
  # Lets the coordinator decide when a participant's transactional callbacks run, instead of Rails running them as each transaction block exits.
  #
  # before_commit must run while every branch is still open, since the callbacks may write.
  # The coordinator runs it early, in passes, and Rails is stopped from running it a second time.
  #
  # after_commit and after_rollback must wait until every participant's transaction has closed.
  # Until then some connections are still enlisted, with Rails believing a transaction is open that MySQL has already finished.
  #
  module TransactionExtension

    # --- Rails' hooks, held back while the coordinator is in charge ---

    # Runs before_commit callbacks, unless the coordinator already ran them.
    #
    # @return [void]
    def before_commit_records
      super unless @xa_runs_before_commit
    end

    # Runs after_commit callbacks, unless the coordinator is holding them.
    #
    # @return [void]
    def commit_records
      super unless @xa_holds_callbacks
    end

    # Runs after_rollback callbacks, unless the coordinator is holding them.
    #
    # @return [void]
    def rollback_records
      super unless @xa_holds_callbacks
    end

    # --- Coordinator API ---

    # Holds after_commit and after_rollback until #xa_release_callbacks!.
    #
    # @return [Boolean] true
    def xa_hold_callbacks!
      @xa_holds_callbacks = true
    end

    # Runs the held callbacks as the coordinator says the global transaction ended, whatever Rails made of its own block.
    # With nil it runs neither set, as Rails does when it cannot tell whether a COMMIT went through.
    #
    # @param action [Symbol, nil] :commit_records, :rollback_records or nil
    # @return [void]
    def xa_release_callbacks!(action)
      @xa_holds_callbacks = false

      public_send(action) if action
    end

    # Whether anything has been enrolled since the last before_commit pass.
    #
    # @return [Boolean] true if records or callbacks are waiting for a pass
    def xa_before_commit_pending?
      records.to_a.size > @xa_records_done.to_i || @callbacks.to_a.size > @xa_callbacks_done.to_i
    end

    # Runs one before_commit pass, for whatever was enrolled since the previous one.
    # Yields once those have run, then counts everything enrolled in the meantime as done.
    # Rails likewise gives no before_commit to records that a transaction's own callbacks add to it.
    #
    # @yield runs while this pass is in progress, so the coordinator can visit other branches
    # @return [void]
    def xa_run_before_commit!
      @xa_runs_before_commit = true
      fresh_records = records.to_a.drop(@xa_records_done.to_i)
      fresh_callbacks = @callbacks.to_a.drop(@xa_callbacks_done.to_i)

      if @run_commit_callbacks
        xa_before_commit(fresh_records)
        fresh_callbacks.each(&:before_commit)
      end

      yield if block_given?
      @xa_records_done = records.to_a.size

      @xa_callbacks_done = @callbacks.to_a.size
    end

    private

      # Runs before_commit on the given records, picking instances the way Transaction#before_commit_records does.
      #
      # @param records [Array<ActiveRecord::Base>] the records enrolled since the last pass
      # @return [void]
      def xa_before_commit(records)
        if ActiveRecord.before_committed_on_all_records
          last_copy = records.each_with_object({}) { |record, copies| copies[record] = record }
          records.uniq(&:__id__).each { |record| record.before_committed! if record.equal?(last_copy[record]) }
        else
          records.uniq.each(&:before_committed!)
        end
      end
  end
end
