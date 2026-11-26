# frozen_string_literal: true

module ActiveXA
  # One database's part in a global transaction, tracking MySQL's XA state:
  #
  #   nil -> :active -> :idle -> :prepared -> :committed
  #                 \________\_________\___-> :rolled_back
  #
  # :in_doubt means this process could not finish the branch and has left it
  # to recovery: its commit decision may be in the log without XA COMMIT
  # having been seen to succeed here, or its rollback failed. Either way the
  # log decides what becomes of it, and nothing here touches it again.
  #
  class Branch
    attr_reader :connection, :xid, :state
    attr_accessor :ar_transaction

    def initialize(connection, xid)
      @connection = connection
      @xid = xid
      @state = nil
    end

    def started?
      !@state.nil?
    end

    def resolved?
      %i[committed rolled_back in_doubt].include?(@state)
    end

    def in_doubt?
      @state == :in_doubt
    end

    # Rails begins the transaction lazily. It begins it again after rolling
    # back a requires_new block that came before the first write, and again
    # on a fresh session when the connection drops before the first write
    # (the server has discarded the old session's branch by then). All of
    # that happens while the block runs. Once the coordinator has begun
    # ending the branch, starting it would reopen an XID that is prepared or
    # already resolved.
    #
    def start!
      if %i[idle prepared committed in_doubt].include?(@state)
        raise UnsupportedOperation, "XA branch #{ xid } is #{ @state } and cannot be started again"
      end

      execute("XA START #{ xid.to_sql(connection) }")

      @state = :active
    end

    def end_and_prepare!
      execute("XA END #{ xid.to_sql(connection) }")
      @state = :idle
      execute("XA PREPARE #{ xid.to_sql(connection) }")

      @state = :prepared
    end

    def commit!
      execute("XA COMMIT #{ xid.to_sql(connection) }")

      @state = :committed
    end

    # For a transaction with a single active branch: no prepare, no log.
    #
    def commit_one_phase!
      execute("XA END #{ xid.to_sql(connection) }")
      @state = :idle
      execute("XA COMMIT #{ xid.to_sql(connection) } ONE PHASE")

      @state = :committed
    end

    def rollback!
      case @state
      when :active
        end_before_rollback
        execute("XA ROLLBACK #{ xid.to_sql(connection) }")
      when :idle, :prepared
        execute("XA ROLLBACK #{ xid.to_sql(connection) }")
      when :in_doubt
        raise Error, "refusing to roll back #{ xid }: its commit decision may be logged"
      end

      @state = :rolled_back unless @state.nil?
    end

    def mark_in_doubt!
      @state = :in_doubt
    end

    # The log settled on abort, so the branch is ours to roll back after all.
    #
    def release_from_doubt!
      @state = :prepared if in_doubt?
    end

    private
      # When a statement in the block was the victim of a deadlock, MySQL has
      # already undone the branch and marked it rollback-only. XA END then
      # fails with XA_RBDEADLOCK, but XA ROLLBACK is still needed to close
      # the branch, and it is the result of that one that counts.
      #
      def end_before_rollback
        execute("XA END #{ xid.to_sql(connection) }")
      rescue ActiveRecord::StatementInvalid
        nil
      end

      def execute(sql)
        connection.send(:internal_execute, sql, "TRANSACTION",
                        allow_retry: false, materialize_transactions: false)
      end
  end
end
