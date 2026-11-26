# frozen_string_literal: true

module ActiveXA

  # Prepended to the MySQL adapters.
  # While a connection is enlisted in an XA transaction, Active Record's own BEGIN, COMMIT and ROLLBACK are rerouted.
  #
  # * BEGIN becomes XA START, issued lazily as Rails materialises the transaction, so a database the block never touches never joins.
  # * COMMIT becomes a no-op: the coordinator commits every branch itself while the Rails transaction blocks are still open.
  # * ROLLBACK becomes XA END and XA ROLLBACK, unless the coordinator has already resolved the branch.
  #
  module AdapterExtension
    attr_accessor :active_xa_branch # the Branch this connection is enlisted in, or nil

    # Starts the XA branch instead of a local transaction.
    #
    # @return [void]
    def begin_db_transaction
      return super unless active_xa_branch

      active_xa_branch.start!
    end

    # Sets the isolation level for the next transaction, then starts the XA branch.
    #
    # @param isolation [Symbol] the isolation level, e.g. :read_committed
    # @return [void]
    def begin_isolated_db_transaction(isolation)
      return super unless active_xa_branch

      internal_execute(
        "SET TRANSACTION ISOLATION LEVEL #{ transaction_isolation_levels.fetch(isolation) }",
        "TRANSACTION", allow_retry: false, materialize_transactions: false
      )

      active_xa_branch.start!
    end

    # Does nothing for an enlisted connection whose branch the coordinator resolved.
    # Reaching it otherwise means Rails is committing without the coordinator, a bug in ActiveXA, so it fails closed.
    #
    # @raise [Error] if the coordinator has not resolved the branch
    # @return [void]
    def commit_db_transaction
      branch = active_xa_branch
      return super unless branch
      return if branch.resolved?

      branch.rollback!

      raise Error, "XA branch #{ branch.xid } reached COMMIT without the coordinator; rolled back"
    end

    # Rolls the XA branch back, unless the coordinator has already resolved it.
    #
    # @return [void]
    def exec_rollback_db_transaction
      branch = active_xa_branch
      return super unless branch
      return if branch.resolved?

      branch.rollback!
    end

    # Reports that ROLLBACK AND CHAIN is unavailable, since it is not valid inside XA.
    # Rails then restarts with a rollback and a fresh XA START under the same XID, which MySQL allows.
    #
    # @return [Boolean] false while enlisted, the adapter's answer otherwise
    def supports_restart_db_transaction?
      return false if active_xa_branch

      super
    end
  end
end
