# frozen_string_literal: true

module ActiveXA
  # Lets the coordinator decide when a participant's transactional callbacks
  # run, instead of Rails running them as each transaction block exits.
  #
  # before_commit must run while every branch is still open, since the
  # callbacks may write. The coordinator runs it early, in passes, and Rails
  # is stopped from running it a second time.
  #
  # after_commit and after_rollback must wait until every participant's
  # transaction has closed. Until then some connections are still enlisted,
  # with Rails believing a transaction is open that MySQL has already
  # finished, and a callback that wrote through one of them would misbehave.
  module TransactionExtension
    def before_commit_records
      super unless @active_xa_runs_before_commit
    end

    def commit_records
      super unless @active_xa_holds_callbacks
    end

    def rollback_records
      super unless @active_xa_holds_callbacks
    end

    def active_xa_hold_callbacks!
      @active_xa_holds_callbacks = true
    end

    # Runs :commit_records or :rollback_records, as the coordinator says the
    # global transaction ended, whatever Rails made of its own block. With
    # nil it runs neither: Rails does the same when it cannot tell whether a
    # COMMIT went through.
    def active_xa_release_callbacks!(action)
      @active_xa_holds_callbacks = false
      public_send(action) if action
    end

    # Has anything been enrolled since the last pass?
    def active_xa_before_commit_pending?
      records.to_a.size > @active_xa_records_done.to_i || @callbacks.to_a.size > @active_xa_callbacks_done.to_i
    end

    # One pass: before_commit for whatever was enrolled since the previous
    # pass. Yields once those have run, then counts everything enrolled here
    # in the meantime as done. Rails likewise gives no before_commit to
    # records that a transaction's own callbacks add to it.
    def active_xa_run_before_commit!
      @active_xa_runs_before_commit = true
      fresh_records = records.to_a.drop(@active_xa_records_done.to_i)
      fresh_callbacks = @callbacks.to_a.drop(@active_xa_callbacks_done.to_i)

      if @run_commit_callbacks
        active_xa_before_commit(fresh_records)
        fresh_callbacks.each(&:before_commit)
      end

      yield if block_given?
      @active_xa_records_done = records.to_a.size
      @active_xa_callbacks_done = @callbacks.to_a.size
    end

    private
      # Picks instances the way Transaction#before_commit_records does.
      def active_xa_before_commit(records)
        if ActiveRecord.before_committed_on_all_records
          last_copy = records.each_with_object({}) { |record, copies| copies[record] = record }
          records.uniq(&:__id__).each { |record| record.before_committed! if record.equal?(last_copy[record]) }
        else
          records.uniq.each(&:before_committed!)
        end
      end
  end
end
