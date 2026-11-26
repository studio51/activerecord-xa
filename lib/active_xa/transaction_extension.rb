# frozen_string_literal: true

module ActiveXA
  # before_commit callbacks must run while every branch is still open, since
  # they may write. Rails would run them only when each block exits, after
  # the coordinator has already committed. The coordinator runs them early,
  # in passes, and this stops Rails running them a second time.
  module TransactionExtension
    def before_commit_records
      super unless @active_xa_runs_before_commit
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
