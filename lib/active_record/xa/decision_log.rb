# frozen_string_literal: true

require "digest"
require "json"

module ActiveRecord::XA

  # Durable record of how global transactions were decided, one row per gtrid.
  #
  # * "commit" is written by the coordinator after every branch has prepared and before the first XA COMMIT, and deleted once every branch has committed.
  # * "abort" is written by recovery before it rolls back a prepared branch that has no decision (presumed abort), and by a coordinator that cannot tell whether its commit row was written.
  #
  # The primary key makes the two exclude each other.
  # That is what keeps a slow coordinator and a recovery run from deciding differently: whoever inserts first wins and the other follows.
  #
  # Rows are written on a connection checked out separately from the pool, so they are never part of the XA transaction, even when the table lives in a participant's database.
  #
  class DecisionLog
    TABLE = "xa_decisions".freeze # the log's table name

    # The DDL for the log's table, for a migration on the decision log's database.
    #
    # @return [String] a CREATE TABLE IF NOT EXISTS statement
    def self.create_table_sql
      <<~SQL
        CREATE TABLE IF NOT EXISTS #{ TABLE } (
          gtrid VARCHAR(64) NOT NULL PRIMARY KEY,
          outcome VARCHAR(8) NOT NULL,
          participants TEXT NOT NULL,
          created_at DATETIME(6) NOT NULL
        ) ENGINE=InnoDB
      SQL
    end

    attr_reader :namespace # eight hex digits that go into every gtrid this log decides

    # Creates a log on a pool.
    # The namespace tells this log's transactions from those of any other ActiveRecord::XA installation whose branches show up in the same XA RECOVER, such as another application on a shared server or another environment of this one.
    # By default it comes from the name of the database the log lives in, which is the same from every app server.
    #
    # @param pool [ActiveRecord::ConnectionAdapters::ConnectionPool] the pool of the database holding the table
    # @param namespace [String, nil] a name to derive the namespace from instead of the database name
    # @return [DecisionLog] the new log
    def initialize(pool, namespace: nil)
      @pool = pool
      @namespace = Digest::SHA256.hexdigest(namespace || pool.db_config.database.to_s)[0, 8]
    end

    # --- Schema ---

    # Creates the log's table if it is missing.
    #
    # @return [void]
    def create_table!
      with_connection { |c| c.execute(self.class.create_table_sql) }
    end

    # --- Decisions ---

    # Logs the decision to commit.
    #
    # @param gtrid [String] the transaction's gtrid
    # @param participants [Array<String>] the database config names that hold a branch, so recovery can tell when it has looked at all of them
    # @raise [ActiveRecord::RecordNotUnique] if the gtrid is already decided
    # @return [void]
    def record_commit!(gtrid, participants)
      insert(gtrid, :commit, participants)
    end

    # Decides "abort" unless a decision is already there.
    #
    # @param gtrid [String] the transaction's gtrid
    # @return [Symbol] the decision that stands, :abort or :commit
    def settle!(gtrid)
      insert(gtrid, :abort, [])

      :abort
    rescue ActiveRecord::RecordNotUnique
      outcome(gtrid) or raise Error, "the decision for #{ gtrid } was removed while it was being read"
    end

    # Reads a transaction's decision.
    #
    # @param gtrid [String] the transaction's gtrid
    # @return [Symbol, nil] :commit, :abort, or nil if undecided
    def outcome(gtrid)
      with_connection do |c|
        c.select_value("SELECT outcome FROM #{ TABLE } WHERE gtrid = #{ c.quote(gtrid) }")&.to_sym
      end
    end

    # Deletes a transaction's decision, once it is no longer needed.
    #
    # @param gtrid [String] the transaction's gtrid
    # @return [void]
    def complete!(gtrid)
      with_connection { |c| c.delete("DELETE FROM #{ TABLE } WHERE gtrid = #{ c.quote(gtrid) }") }
    end

    # Lists every gtrid in the log.
    #
    # @return [Array<String>] the gtrids
    def entries
      with_connection { |c| c.select_values("SELECT gtrid FROM #{ TABLE }") }
    end

    # --- Pruning ---

    # Reads the log database's clock, which also stamps the rows.
    # Ages are worked out against it in SQL, so no other clock comes into pruning.
    #
    # @return [String] the current UTC time, with microseconds
    def now
      with_connection { |c| c.select_value("SELECT CAST(UTC_TIMESTAMP(6) AS CHAR)") }
    end

    # Lists decisions old enough to prune.
    #
    # @param time [String] the reference time, a value from #now
    # @param commit_age [Numeric] seconds a commit decision must be old
    # @param abort_age [Numeric] seconds an abort marker must be old
    # @return [Array<Array(String, Array<String>)>] [gtrid, participants] pairs
    def expired(time, commit_age:, abort_age:)
      rows = with_connection do |c|
        c.select_rows(<<~SQL)
          SELECT gtrid, participants FROM #{ TABLE }
          WHERE created_at <= CAST(#{ c.quote(time) } AS DATETIME(6)) - INTERVAL
            (CASE outcome WHEN 'commit' THEN #{ microseconds(commit_age) } ELSE #{ microseconds(abort_age) } END) MICROSECOND
        SQL
      end

      rows.map { |gtrid, participants| [ gtrid, JSON.parse(participants) ] }
    end

    private

      # Inserts a decision row, stamped by the database clock.
      #
      # @param gtrid [String] the transaction's gtrid
      # @param outcome [Symbol] :commit or :abort
      # @param participants [Array<String>] the database config names that hold a branch
      # @return [void]
      def insert(gtrid, outcome, participants)
        with_connection do |c|
          c.insert(
            "INSERT INTO #{ TABLE } (gtrid, outcome, participants, created_at) VALUES " \
            "(#{ c.quote(gtrid) }, #{ c.quote(outcome.to_s) }, #{ c.quote(JSON.generate(participants)) }, UTC_TIMESTAMP(6))",
            "ActiveRecord::XA"
          )
        end
      end

      # Converts seconds to whole microseconds for an SQL interval.
      #
      # @param seconds [Numeric] the duration
      # @return [Integer] the duration in microseconds
      def microseconds(seconds)
        (seconds * 1_000_000).round
      end

      # Checks out a connection of its own, outside any transaction, and reads it uncached so a caller with the query cache on still sees the log as it is now.
      #
      # @yieldparam connection [ActiveRecord::ConnectionAdapters::AbstractAdapter] the connection
      # @return [Object] the block's value
      def with_connection
        connection = @pool.checkout
        connection.uncached { yield connection }
      ensure
        @pool.checkin(connection) if connection
      end
  end
end
