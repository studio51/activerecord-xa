# frozen_string_literal: true

require "json"

module ActiveXA
  # Durable record of "commit" decisions (presumed abort: an XID with no row
  # here was never decided, so recovery rolls it back once it's old enough).
  #
  # The row is written after every branch has prepared and before the first
  # XA COMMIT, and deleted once every branch has committed. It is written on
  # a connection checked out separately from the pool, so it is never part
  # of the XA transaction even when it lives in a participant's database.
  class DecisionLog
    TABLE = "active_xa_decisions"

    def self.create_table_sql
      <<~SQL
        CREATE TABLE IF NOT EXISTS #{TABLE} (
          gtrid VARCHAR(64) NOT NULL PRIMARY KEY,
          participants TEXT NOT NULL,
          created_at DATETIME(6) NOT NULL
        ) ENGINE=InnoDB
      SQL
    end

    def initialize(pool)
      @pool = pool
    end

    def create_table!
      with_connection { |c| c.execute(self.class.create_table_sql) }
    end

    def record_commit!(gtrid, branches)
      participants = JSON.generate(branches.map { |b| b.xid.bqual })
      with_connection do |c|
        c.insert(
          "INSERT INTO #{TABLE} (gtrid, participants, created_at) " \
          "VALUES (#{c.quote(gtrid)}, #{c.quote(participants)}, #{c.quote(Time.now.utc)})",
          "ActiveXA"
        )
      end
    end

    def committed?(gtrid)
      with_connection do |c|
        c.select_value("SELECT 1 FROM #{TABLE} WHERE gtrid = #{c.quote(gtrid)}") ? true : false
      end
    end

    def complete!(gtrid)
      with_connection { |c| c.delete("DELETE FROM #{TABLE} WHERE gtrid = #{c.quote(gtrid)}") }
    end

    def entries
      with_connection { |c| c.select_values("SELECT gtrid FROM #{TABLE}") }
    end

    private
      def with_connection
        connection = @pool.checkout
        yield connection
      ensure
        @pool.checkin(connection) if connection
      end
  end
end
