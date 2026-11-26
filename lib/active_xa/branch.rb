# frozen_string_literal: true

module ActiveXA
  # One database's part in a global transaction, tracking MySQL's XA state:
  #
  #   nil -> :active -> :idle -> :prepared -> :committed
  #                 \________\_________\___-> :rolled_back
  #
  # :in_doubt means the commit decision is logged but XA COMMIT failed here.
  # The branch must never be rolled back; recovery will commit it.
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

    def start!
      execute("XA START #{xid.to_sql(connection)}")
      @state = :active
    end

    def end_and_prepare!
      execute("XA END #{xid.to_sql(connection)}")
      @state = :idle
      execute("XA PREPARE #{xid.to_sql(connection)}")
      @state = :prepared
    end

    def commit!
      execute("XA COMMIT #{xid.to_sql(connection)}")
      @state = :committed
    end

    # For a transaction with a single active branch: no prepare, no log.
    def commit_one_phase!
      execute("XA END #{xid.to_sql(connection)}")
      @state = :idle
      execute("XA COMMIT #{xid.to_sql(connection)} ONE PHASE")
      @state = :committed
    end

    def rollback!
      case @state
      when :active
        execute("XA END #{xid.to_sql(connection)}")
        execute("XA ROLLBACK #{xid.to_sql(connection)}")
      when :idle, :prepared
        execute("XA ROLLBACK #{xid.to_sql(connection)}")
      when :in_doubt
        raise Error, "refusing to roll back #{xid}: commit decision already logged"
      end
      @state = :rolled_back unless @state.nil?
    end

    def mark_in_doubt!
      @state = :in_doubt
    end

    private
      def execute(sql)
        connection.send(:internal_execute, sql, "TRANSACTION",
                        allow_retry: false, materialize_transactions: false)
      end
  end
end
