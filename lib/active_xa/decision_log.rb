# frozen_string_literal: true

require "digest"
require "json"

module ActiveXA
  # Durable record of how global transactions were decided, one row per
  # gtrid:
  #
  # * "commit" is written by the coordinator after every branch has prepared
  #   and before the first XA COMMIT, and deleted once every branch has
  #   committed.
  # * "abort" is written by recovery before it rolls back a prepared branch
  #   that has no decision (presumed abort), and by a coordinator that
  #   cannot tell whether its commit row was written.
  #
  # The primary key makes the two exclude each other. That is what keeps a
  # slow coordinator and a recovery run from deciding differently: whoever
  # inserts first wins and the other follows.
  #
  # Rows are written on a connection checked out separately from the pool,
  # so they are never part of the XA transaction even when the table lives
  # in a participant's database.
  #
  class DecisionLog
    TABLE = "active_xa_decisions"

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

    # Tells this log's transactions from those of any other ActiveXA
    # installation whose branches show up in the same XA RECOVER: another
    # application on a shared server, or another environment of this one.
    # It goes into every gtrid, and recovery leaves other namespaces alone.
    #
    attr_reader :namespace

    # By default the namespace comes from the name of the database the log
    # lives in, which is the same from every app server.
    #
    def initialize(pool, namespace: nil)
      @pool = pool
      @namespace = Digest::SHA256.hexdigest(namespace || pool.db_config.database.to_s)[0, 8]
    end

    def create_table!
      with_connection { |c| c.execute(self.class.create_table_sql) }
    end

    # +participants+ names the databases that hold a branch, so that recovery
    # can tell when it has looked at all of them. Raises
    # ActiveRecord::RecordNotUnique if the gtrid is already decided.
    #
    def record_commit!(gtrid, participants)
      insert(gtrid, :commit, participants)
    end

    # Decides "abort" unless a decision is already there. Returns the
    # decision that stands, :abort or :commit.
    #
    def settle!(gtrid)
      insert(gtrid, :abort, [])
      :abort
    rescue ActiveRecord::RecordNotUnique
      outcome(gtrid) or raise Error, "the decision for #{ gtrid } was removed while it was being read"
    end

    def outcome(gtrid)
      with_connection do |c|
        c.select_value("SELECT outcome FROM #{ TABLE } WHERE gtrid = #{ c.quote(gtrid) }")&.to_sym
      end
    end

    def complete!(gtrid)
      with_connection { |c| c.delete("DELETE FROM #{ TABLE } WHERE gtrid = #{ c.quote(gtrid) }") }
    end

    def entries
      with_connection { |c| c.select_values("SELECT gtrid FROM #{ TABLE }") }
    end

    # The log database's clock, which also stamps the rows. Ages are worked
    # out against it in SQL, so no other clock comes into pruning.
    #
    def now
      with_connection { |c| c.select_value("SELECT CAST(UTC_TIMESTAMP(6) AS CHAR)") }
    end

    # Decisions old enough to prune as of +time+ (a value from #now): commits
    # after +commit_age+ seconds, abort markers after +abort_age+. Returns
    # [gtrid, participants] pairs.
    #
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
      def insert(gtrid, outcome, participants)
        with_connection do |c|
          c.insert(
            "INSERT INTO #{ TABLE } (gtrid, outcome, participants, created_at) VALUES " \
            "(#{ c.quote(gtrid) }, #{ c.quote(outcome.to_s) }, #{ c.quote(JSON.generate(participants)) }, UTC_TIMESTAMP(6))",
            "ActiveXA"
          )
        end
      end

      def microseconds(seconds)
        (seconds * 1_000_000).round
      end

      # Uncached, so a caller with the query cache on still reads the log as
      # it is now.
      #
      def with_connection
        connection = @pool.checkout
        connection.uncached { yield connection }
      ensure
        @pool.checkin(connection) if connection
      end
  end
end
