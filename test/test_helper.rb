# frozen_string_literal: true

# Runs against a real MySQL 8.0.30+ server with two databases.
#   MYSQL_HOST, MYSQL_USER, MYSQL_PASSWORD   (defaults: localhost, xa, xa)
#   RAILS_SRC=/path/to/rails  to load Rails from a source checkout instead of gems
if (src = ENV["RAILS_SRC"])
  %w[activesupport activemodel activerecord].each { |g| $LOAD_PATH.unshift File.join(src, g, "lib") }
end
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

ENV["RAILS_ENV"] = "test"
require "minitest/autorun"
require "active_xa"

base = {
  adapter: "mysql2",
  host: ENV.fetch("MYSQL_HOST", "localhost"),
  username: ENV.fetch("MYSQL_USER", "xa"),
  password: ENV.fetch("MYSQL_PASSWORD", "xa"),
  pool: 5,
}
# A second pool on the tracker database whose name is 36 characters but 108
# bytes, to check that XIDs respect MySQL's byte limits.
WIDE_NAME = "数据库" * 12
ActiveRecord::Base.configurations = {
  "test" => {
    "primary" => base.merge(database: "xa_primary"),
    "tracker" => base.merge(database: "xa_tracker"),
    WIDE_NAME => base.merge(database: "xa_tracker"),
  },
}
ActiveRecord::Base.logger = Logger.new(ENV["SQL_LOG"] ? $stdout : nil)

class PrimaryRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :primary }
end

class TrackerRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :tracker }
end

class WideNameRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: WIDE_NAME.to_sym }
end

module Events
  def self.log = (@log ||= [])
  def self.clear = log.clear
end

class Order < PrimaryRecord
  after_commit { Events.log << [:order_after_commit, id] }
  after_rollback { Events.log << [:order_after_rollback] }
end

class TrackerEvent < TrackerRecord
  attr_accessor :check_order_visible

  before_commit { Events.log << [:tracker_before_commit] }
  after_commit do
    if check_order_visible
      # Read through an unrelated connection: is the primary write durable?
      pool = PrimaryRecord.connection_pool
      conn = pool.checkout
      begin
        Events.log << [:order_visible_in_tracker_after_commit,
                       conn.select_value("SELECT COUNT(*) FROM orders").to_i]
      ensure
        pool.checkin(conn)
      end
    end
  end
end

class WideNameEvent < WideNameRecord
  self.table_name = "tracker_events"
end

PrimaryRecord.connection.execute("DROP TABLE IF EXISTS orders")
PrimaryRecord.connection.execute(
  "CREATE TABLE orders (id BIGINT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(50), audit VARCHAR(50)) ENGINE=InnoDB"
)
TrackerRecord.connection.execute("DROP TABLE IF EXISTS tracker_events")
TrackerRecord.connection.execute(
  "CREATE TABLE tracker_events (id BIGINT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(50)) ENGINE=InnoDB"
)
PrimaryRecord.connection.execute("DROP TABLE IF EXISTS #{ActiveXA::DecisionLog::TABLE}")

ActiveXA.configure do |c|
  c.decision_log_class = PrimaryRecord
  c.logger = Logger.new(nil)
end
ActiveXA.decision_log.create_table!

# Lets tests make a specific XA step fail on a specific database.
module FaultInjection
  class << self
    attr_accessor :rules # { method_name => /bqual pattern/ }
  end
  self.rules = {}

  %i[end_and_prepare! commit! commit_one_phase!].each do |name|
    define_method(name) do |*args|
      pattern = FaultInjection.rules[name]
      raise ActiveRecord::StatementInvalid, "injected #{name} failure" if pattern&.match?(xid.bqual)

      super(*args)
    end
  end
end
ActiveXA::Branch.prepend(FaultInjection)

class ActiveXATestCase < Minitest::Test
  def setup
    FaultInjection.rules = {}
    Events.clear
    rollback_stray_xa
    Order.delete_all
    TrackerEvent.delete_all
    PrimaryRecord.connection.execute("DELETE FROM #{ActiveXA::DecisionLog::TABLE}")
    ActiveXA.config.on_incomplete_commit = nil
  end

  def counts
    [Order.count, TrackerEvent.count]
  end

  def prepared_xids(klass)
    klass.connection.select_rows("XA RECOVER").select { |r| r[0].to_i == ActiveXA::Xid::FORMAT_ID }
  end

  # Runs the block in a thread that holds no connections yet, like a fresh
  # request or job, and returns its value.
  def in_new_thread(&block)
    Thread.new(&block).tap { |t| t.report_on_exception = false }.value
  end

  def leased_connections
    [PrimaryRecord, TrackerRecord].filter_map { |klass| klass.connection_pool.active_connection? }
  end

  private
    def rollback_stray_xa
      [PrimaryRecord, TrackerRecord].each do |klass|
        prepared_xids(klass).each do |_f, gl, bl, data|
          gl = gl.to_i
          sql = "#{klass.connection.quote(data[0, gl])},#{klass.connection.quote(data[gl, bl.to_i])},#{ActiveXA::Xid::FORMAT_ID}"
          klass.connection.execute("XA ROLLBACK #{sql}")
        end
      end
    end
end
