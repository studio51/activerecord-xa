# frozen_string_literal: true

module ActiveXA
  # before_commit callbacks must run while every branch is still open, since
  # they may write. Rails would run them only when each block exits, after
  # the coordinator has already committed. The coordinator runs them early
  # and this guard stops Rails running them a second time.
  module TransactionExtension
    def before_commit_records
      return if @active_xa_before_commit_ran

      super
    end

    def active_xa_run_before_commit!
      return if @active_xa_before_commit_ran

      before_commit_records
      @active_xa_before_commit_ran = true
    end
  end
end
