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
require "minitest/mock"
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
    # Nothing listens here, so connecting fails at once.
    "unreachable" => base.merge(database: "xa_primary", host: "127.0.0.1", port: 1),
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

class UnreachableRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :unreachable }
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

# Records whose transactional callbacks run whatever a test hands them.
module Hooked
  def self.included(model)
    model.attr_accessor :on_before_commit, :on_after_commit, :on_after_rollback
    model.before_commit { on_before_commit&.call }
    model.after_commit { on_after_commit&.call }
    model.after_rollback { on_after_rollback&.call }
  end
end

class HookedOrder < PrimaryRecord
  self.table_name = "orders"
  include Hooked
end

class HookedEvent < TrackerRecord
  self.table_name = "tracker_events"
  include Hooked
end

# A prepared branch outlives the process that made it and keeps its metadata
# locks, so one left behind by an earlier run would block the DROP TABLE
# below forever. Clear them here, and again before every test.
module StrayXA
  def self.prepared(klass)
    klass.connection.select_rows("XA RECOVER").select { |row| row[0].to_i == ActiveXA::Xid::FORMAT_ID }
  end

  def self.rollback!
    [PrimaryRecord, TrackerRecord].each do |klass|
      prepared(klass).each do |_format_id, gtrid_length, bqual_length, data|
        gl = gtrid_length.to_i
        xid = ActiveXA::Xid.new(data.byteslice(0, gl), data.byteslice(gl, bqual_length.to_i))
        klass.connection.execute("XA ROLLBACK #{xid.to_sql(klass.connection)}")
      end
    end
  end
end
StrayXA.rollback!

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
    # { method_name => /bqual pattern/ } raises StatementInvalid there;
    # { method_name => [/bqual pattern/, callable] } runs the callable instead.
    attr_accessor :rules
  end
  self.rules = {}

  %i[end_and_prepare! commit! commit_one_phase!].each do |name|
    define_method(name) do |*args|
      pattern, fault = FaultInjection.rules[name]
      if pattern&.match?(xid.bqual)
        fault ? fault.call : raise(ActiveRecord::StatementInvalid, "injected #{name} failure")
      end

      super(*args)
    end
  end
end
ActiveXA::Branch.prepend(FaultInjection)

# Not a StandardError: stands in for Interrupt, or for the exception a
# request timeout raises into a thread.
class Stop < Exception; end

class ActiveXATestCase < Minitest::Test
  def setup
    FaultInjection.rules = {}
    Events.clear
    StrayXA.rollback!
    Order.delete_all
    TrackerEvent.delete_all
    PrimaryRecord.connection.execute("DELETE FROM #{ActiveXA::DecisionLog::TABLE}")
    ActiveXA.config.on_incomplete_commit = nil
  end

  def counts
    [Order.count, TrackerEvent.count]
  end

  def prepared_xids(klass)
    StrayXA.prepared(klass)
  end

  # Runs the block in a thread that holds no connections yet, like a fresh
  # request or job, and returns its value.
  def in_new_thread(&block)
    Thread.new(&block).tap { |t| t.report_on_exception = false }.value
  end

  def leased_connections
    [PrimaryRecord, TrackerRecord].filter_map { |klass| klass.connection_pool.active_connection? }
  end

  def new_gtrid(namespace = ActiveXA.decision_log.namespace)
    ActiveXA::Xid.generate_gtrid(namespace)
  end

  def recover(grace:, abort_retention: 3600)
    ActiveXA::Recovery.new([PrimaryRecord, TrackerRecord], log: ActiveXA.decision_log,
                                                           grace: grace, abort_retention: abort_retention).run
  end

  # Runs the block with a decision log that calls +before+ and +after+
  # around the commit insert, and yields that log.
  def with_decision_log(before: nil, after: nil)
    log = ActiveXA.decision_log
    log.singleton_class.prepend(Module.new do
      define_method(:record_commit!) do |gtrid, participants|
        before&.call(gtrid)
        super(gtrid, participants)
        after&.call(gtrid)
      end
    end)
    ActiveXA.stub(:decision_log, log) { yield log }
  end

  # Runs the block as a transaction that started an hour ago, well past any
  # grace period, and returns its gtrid.
  def long_running_transaction(&block)
    gtrid = new_gtrid.sub(/-\d+-/) { "-#{((Time.now.to_f - 3600) * 1000).to_i}-" }
    ActiveXA::Xid.stub(:generate_gtrid, gtrid, &block)
    gtrid
  end
end
