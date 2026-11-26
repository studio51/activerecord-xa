# frozen_string_literal: true

module ActiveRecord::XA

  # One database's part in a global transaction, tracking MySQL's XA state.
  #
  #   nil -> :active -> :idle -> :prepared -> :committed
  #                 \________\_________\___-> :rolled_back
  #
  # :in_doubt means this process could not finish the branch and has left it to recovery.
  # Either its commit decision may be in the log without XA COMMIT having been seen to succeed here, or its rollback failed.
  # The log decides what becomes of it, and nothing in this process touches it again.
  #
  class Branch
    attr_reader :connection # the participant's Active Record connection
    attr_reader :xid        # the branch's Xid
    attr_reader :state      # the XA state, as above
    attr_accessor :ar_transaction # the Rails transaction the branch runs inside

    # --- States ---

    # States from which Rails may (re)start the branch.
    #
    STARTABLE = [ nil, :active, :rolled_back ].freeze

    # States in which the branch is finished as far as this process is concerned.
    #
    RESOLVED = %i[committed rolled_back in_doubt].freeze

    # Creates a branch that has not started yet.
    #
    # @param connection [ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter] the participant's connection
    # @param xid [Xid] the branch's XID
    # @return [Branch] the new branch
    def initialize(connection, xid)
      @connection = connection
      @xid = xid
      @state = nil
    end

    # --- Queries ---

    # Whether XA START has run, i.e. the block touched this database.
    #
    # @return [Boolean] true once the branch has started
    def started?
      !@state.nil?
    end

    # Whether the branch needs nothing more from Rails' own COMMIT or ROLLBACK.
    #
    # @return [Boolean] true when committed, rolled back or left to recovery
    def resolved?
      RESOLVED.include?(@state)
    end

    # Whether the branch has been left to recovery.
    #
    # @return [Boolean] true when in doubt
    def in_doubt?
      @state == :in_doubt
    end

    # --- XA statements ---

    # Issues XA START.
    # Rails begins the transaction lazily, begins it again after rolling back a requires_new block that came before the first write, and again on a fresh session when the connection drops before the first write.
    # All of that happens while the block runs.
    # Once the coordinator has begun ending the branch, starting it would reopen an XID that is prepared or already resolved.
    #
    # @raise [UnsupportedOperation] if the coordinator has begun ending the branch
    # @return [Symbol] the new state, :active
    def start!
      unless STARTABLE.include?(@state)
        raise UnsupportedOperation, "XA branch #{ xid } is #{ @state } and cannot be started again"
      end

      execute("XA START #{ xid.to_sql(connection) }")

      @state = :active
    end

    # Issues XA END and XA PREPARE: phase one of the commit.
    #
    # @return [Symbol] the new state, :prepared
    def end_and_prepare!
      execute("XA END #{ xid.to_sql(connection) }")
      @state = :idle
      execute("XA PREPARE #{ xid.to_sql(connection) }")

      @state = :prepared
    end

    # Issues XA COMMIT on a prepared branch: phase two of the commit.
    #
    # @return [Symbol] the new state, :committed
    def commit!
      execute("XA COMMIT #{ xid.to_sql(connection) }")

      @state = :committed
    end

    # Commits a transaction whose only active branch is this one, with no prepare and no log.
    #
    # @return [Symbol] the new state, :committed
    def commit_one_phase!
      execute("XA END #{ xid.to_sql(connection) }")
      @state = :idle
      execute("XA COMMIT #{ xid.to_sql(connection) } ONE PHASE")

      @state = :committed
    end

    # Rolls the branch back from whichever state it is in.
    # A branch that never started has nothing to roll back.
    #
    # @raise [Error] if the branch is in doubt, since its commit decision may be logged
    # @return [Symbol, nil] the new state, :rolled_back, or nil if it never started
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

    # --- Recovery hand-off ---

    # Leaves the branch to recovery: nothing in this process will commit or roll it back.
    #
    # @return [Symbol] the new state, :in_doubt
    def mark_in_doubt!
      @state = :in_doubt
    end

    # Takes the branch back after the log settled on abort, so this process can roll it back after all.
    #
    # @return [Symbol, nil] :prepared if the branch was in doubt, nil otherwise
    def release_from_doubt!
      @state = :prepared if in_doubt?
    end

    private

      # Issues XA END ahead of a rollback, ignoring a failure.
      # When a statement in the block was the victim of a deadlock, MySQL has already undone the branch and marked it rollback-only.
      # XA END then fails with XA_RBDEADLOCK, but XA ROLLBACK is still needed to close the branch, and its result is the one that counts.
      #
      # @return [void]
      def end_before_rollback
        execute("XA END #{ xid.to_sql(connection) }")
      rescue ActiveRecord::StatementInvalid
        nil
      end

      # Runs an XA statement without retrying it and without materialising Rails' lazy transactions.
      #
      # @param sql [String] the statement
      # @return [ActiveRecord::Result] the result
      def execute(sql)
        connection.send(:internal_execute, sql, "TRANSACTION",
                        allow_retry: false, materialize_transactions: false)
      end
  end
end
