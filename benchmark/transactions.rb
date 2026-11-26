# frozen_string_literal: true

# Measures what ActiveRecord::XA costs per transaction, against the alternatives.
#
#   MYSQL_HOST=127.0.0.1 bundle exec ruby benchmark/transactions.rb [iterations]
#
# Uses the test databases (xa_primary, xa_tracker) and the same environment
# variables as the test suite. Each scenario writes one row per database it
# touches. Never run it against a server with data you care about: it drops
# and recreates its own tables.
#
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "active_record/xa"
require "mysql2"

ENV["RAILS_ENV"] ||= "development"

ITERATIONS = Integer(ARGV.fetch(0, 2_000))
WARMUP     = 200

base = {
  adapter: "mysql2",
  host: ENV.fetch("MYSQL_HOST", "localhost"),
  username: ENV.fetch("MYSQL_USER", "xa"),
  password: ENV.fetch("MYSQL_PASSWORD", "xa"),
  pool: 5
}
ActiveRecord::Base.configurations = {
  "development" => {
    "primary" => base.merge(database: "xa_primary"),
    "tracker" => base.merge(database: "xa_tracker")
  }
}

class PrimaryRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :primary }
end

class TrackerRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :tracker }
end

class BenchOrder < PrimaryRecord
  self.table_name = "bench_orders"
end

class BenchEvent < TrackerRecord
  self.table_name = "bench_events"
end

[ [ PrimaryRecord, "bench_orders" ], [ TrackerRecord, "bench_events" ] ].each do |klass, table|
  klass.connection.execute("DROP TABLE IF EXISTS #{ table }")
  klass.connection.execute("CREATE TABLE #{ table } (id BIGINT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(50)) ENGINE=InnoDB")
end

ActiveRecord::XA.configure do |c|
  c.decision_log_class = PrimaryRecord
  c.logger = nil
end
ActiveRecord::XA.decision_log.create_table!

SCENARIOS = {
  "one database, plain transaction" => -> {
    PrimaryRecord.transaction { BenchOrder.create!(name: "order") }
  },
  "two databases, nested plain transactions (not atomic)" => -> {
    PrimaryRecord.transaction do
      TrackerRecord.transaction do
        BenchEvent.create!(name: "event")
        BenchOrder.create!(name: "order")
      end
    end
  },
  "ActiveRecord::XA, one database touched (one-phase)" => -> {
    ActiveRecord::XA.transaction(PrimaryRecord, TrackerRecord) { BenchOrder.create!(name: "order") }
  },
  "ActiveRecord::XA, two databases (two-phase + decision log)" => -> {
    ActiveRecord::XA.transaction(PrimaryRecord, TrackerRecord) do
      BenchEvent.create!(name: "event")
      BenchOrder.create!(name: "order")
    end
  }
}.freeze

def measure(work)
  WARMUP.times { work.call }

  ITERATIONS.times.map do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    work.call
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end.sort
end

def ms(seconds) = format("%.2f", seconds * 1000)

server = PrimaryRecord.connection.select_rows(
  "SELECT @@version, @@innodb_flush_log_at_trx_commit, @@sync_binlog, @@log_bin"
).first

puts "MySQL #{ server[0] }, innodb_flush_log_at_trx_commit=#{ server[1] }, sync_binlog=#{ server[2] }, log_bin=#{ server[3] }"
puts "Ruby #{ RUBY_VERSION }, Active Record #{ ActiveRecord.version }, #{ ITERATIONS } transactions per scenario"
puts
puts "| Scenario | Mean (ms) | p50 (ms) | p99 (ms) | Transactions/s |"
puts "|---|---:|---:|---:|---:|"

SCENARIOS.each do |name, work|
  samples = measure(work)
  mean = samples.sum / samples.size

  puts "| #{ name } | #{ ms(mean) } | #{ ms(samples[samples.size / 2]) } | " \
       "#{ ms(samples[(samples.size * 0.99).floor]) } | #{ (1 / mean).round } |"
end
