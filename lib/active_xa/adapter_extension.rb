# frozen_string_literal: true

module ActiveXA
  # Prepended to the MySQL adapters. While a connection is enlisted in an XA
  # transaction, Active Record's own BEGIN/COMMIT/ROLLBACK are rerouted:
  #
  # * BEGIN becomes XA START, issued lazily as Rails materialises the
  #   transaction, so a database the block never touches never joins.
  # * COMMIT becomes a no-op: the coordinator commits every branch itself
  #   while the Rails transaction blocks are still open, so by the time Rails
  #   "commits" (and runs after_commit callbacks) the data is durable.
  # * ROLLBACK becomes XA END + XA ROLLBACK, unless the coordinator has
  #   already resolved the branch.
  module AdapterExtension
    attr_accessor :active_xa_branch

    def begin_db_transaction
      return super unless active_xa_branch

      active_xa_branch.start!
    end

    def begin_isolated_db_transaction(isolation)
      return super unless active_xa_branch

      internal_execute(
        "SET TRANSACTION ISOLATION LEVEL #{transaction_isolation_levels.fetch(isolation)}",
        "TRANSACTION", allow_retry: false, materialize_transactions: false
      )
      active_xa_branch.start!
    end

    def commit_db_transaction
      branch = active_xa_branch
      return super unless branch
      return if branch.resolved?

      # Only reachable if Rails commits without the coordinator having run,
      # which would be a bug in ActiveXA. Fail closed.
      branch.rollback!
      raise Error, "XA branch #{branch.xid} reached COMMIT without the coordinator; rolled back"
    end

    def exec_rollback_db_transaction
      branch = active_xa_branch
      return super unless branch
      return if branch.resolved?

      branch.rollback!
    end

    # ROLLBACK AND CHAIN isn't valid inside XA. Rails falls back to
    # rollback + re-materialise, i.e. XA ROLLBACK then XA START again with
    # the same xid, which MySQL allows.
    def supports_restart_db_transaction?
      return false if active_xa_branch

      super
    end
  end
end
