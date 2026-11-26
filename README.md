# ActiveXA

> Atomic transactions across multiple MySQL databases for Active Record.

[![CI](https://github.com/studio51/activerecord-xa/actions/workflows/ci.yml/badge.svg)](https://github.com/studio51/activerecord-xa/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Nested `transaction` blocks on different databases look atomic, but they are two independent transactions:

```ruby
PrimaryRecord.transaction do
  TrackerRecord.transaction do
    TrackerEvent.create!(name: "order placed")
  end                                    # the tracker commits here
  Order.create!(total: 0)                # raises: the order rolls back,
end                                      # the tracker event stays
```

ActiveXA runs them as one transaction using MySQL's XA two-phase commit, so every database commits or none does:

```ruby
ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
  TrackerEvent.create!(name: "order placed")
  Order.create!(total: 0)                # raises: both roll back
end
```

Inside the block you use models exactly as normal.

## Why use it

- **All or nothing across databases.** A failure anywhere, at any point before the commit decision, rolls back every database.
- **Survives crashes.** The decision is written to a durable log before anything commits. If the process dies halfway, `ActiveXA.recover!` finishes the job, the same way on every database.
- **Plain Rails inside.** Validations, callbacks, `requires_new` savepoints, `ActiveRecord::Rollback`, isolation levels and early `return` all behave as they do in a normal transaction.
- **`after_commit` you can trust.** Callbacks run once the data is durable on every database, so a job enqueued from `after_commit` never sees half a transaction.
- **Pay only for what you touch.** A database the block never queries never joins. If only one is touched, the commit is a single `XA COMMIT ... ONE PHASE` with no log write.
- **Small, with nothing to run.** About 650 lines of code on top of Active Record; no coordinator service, no queue, no extra infrastructure.

## Installation

```ruby
# Gemfile
gem "active_xa"
```

```sh
bundle install
bin/rails generate active_xa:install          # add --database NAME if the log should live elsewhere
bin/rails db:migrate
```

The generator writes `config/initializers/active_xa.rb` and a migration for the decision log table. List your databases in the initializer:

```ruby
ActiveXA.configure do |config|
  config.decision_log_class = "ApplicationRecord"           # where the decision log lives
  config.participants       = %w[ApplicationRecord LedgerRecord]
  config.on_incomplete_commit = ->(gtrid, failures) { Rails.error.report(ActiveXA::Error.new("XA in doubt: #{ gtrid }")) }
end
```

Then run recovery on a schedule, for example every minute with Solid Queue:

```yaml
# config/recurring.yml
production:
  active_xa_recovery:
    command: "ActiveXA.recover!"
    schedule: every minute
```

or from cron with `bin/rails active_xa:recover`.

## Examples

### Moving money between two databases

```ruby
class Transfer
  def self.call(from:, to:, amount:)
    ActiveXA.transaction(ApplicationRecord, LedgerRecord) do
      from.lock!.decrement!(:balance, amount)
      to.lock!.increment!(:balance, amount)
      LedgerEntry.create!(from_id: from.id, to_id: to.id, amount:)
    end
  end
end
```

If the ledger insert fails, neither balance changes.

### Writing to an analytics or tracking database alongside the main one

```ruby
ActiveXA.transaction(ApplicationRecord, TrackingRecord) do
  order = Order.create!(order_params)
  TrackingEvent.create!(name: "order.created", subject: order)
end
```

### Rolling back on purpose

```ruby
ActiveXA.transaction(ApplicationRecord, LedgerRecord) do
  invoice = Invoice.create!(attrs)
  LedgerEntry.create!(invoice:)
  raise ActiveRecord::Rollback if invoice.total.zero?   # both roll back, nothing is raised
end
```

### Returning a value, or leaving early

```ruby
order = ActiveXA.transaction(ApplicationRecord, LedgerRecord) do
  Order.create!(attrs).tap { |o| LedgerEntry.create!(order: o) }
end

def place(attrs)
  ActiveXA.transaction(ApplicationRecord, LedgerRecord) do
    order = Order.create!(attrs)
    return order if order.free?     # commits, as `return` does in a Rails transaction
    LedgerEntry.create!(order:)
    order
  end
end
```

### Callbacks

```ruby
class Order < ApplicationRecord
  after_create_commit { FulfilmentJob.perform_later(self) }  # runs once both databases have committed
  after_rollback      { Rails.logger.info("order #{ id } rolled back") }
end
```

`before_commit` callbacks run while every database is still open, so they may write to either one, and records saved by another database's callbacks get theirs too.

### Nested transactions and savepoints

```ruby
ActiveXA.transaction(ApplicationRecord, LedgerRecord) do
  order = Order.create!(attrs)

  Order.transaction(requires_new: true) do     # a savepoint inside the XA branch
    Coupon.redeem!(code)
  rescue Coupon::Expired
    raise ActiveRecord::Rollback                # undoes only the coupon
  end

  LedgerEntry.create!(order:)
end
```

### Retrying a deadlock

A deadlock victim rolls back everywhere and raises `ActiveRecord::Deadlocked`, so the usual retry works:

```ruby
attempts = 0
begin
  Transfer.call(from:, to:, amount:)
rescue ActiveRecord::Deadlocked
  retry if (attempts += 1) < 3
  raise
end
```

### Handling commit failures

```ruby
begin
  ActiveXA.transaction(ApplicationRecord, LedgerRecord) { ... }
rescue ActiveXA::PrepareFailed, ActiveXA::DecisionLogFailed
  # Rolled back everywhere. Safe to retry.
rescue ActiveXA::OutcomeUnknown
  # The decision log was unreachable at the critical moment. Nothing was
  # rolled back; recovery will finish the transaction one way or the other.
  # Do not retry blindly: check whether the work landed first.
end
```

Once the commit decision is logged the transaction counts as committed. A database that then fails to apply `XA COMMIT` does not raise: `on_incomplete_commit` is called and recovery applies it.

### Checking what recovery did

```ruby
report = ActiveXA.recover!
report.committed     # => [#<ActiveXA::Xid ...>]  branches committed from the log
report.rolled_back   # => branches with no decision, rolled back (presumed abort)
report.skipped       # => branches younger than the grace period
report.errors        # => [[subject, exception], ...]
```

## Performance

Two-phase commit costs extra round trips and extra durable writes. A transaction that writes one row to each of two databases:

| | Statements | Durable flushes |
|---|---:|---:|
| Nested plain transactions | 6 | 2 |
| ActiveXA, one database touched | 4 | 1 |
| ActiveXA, two databases | 12 | 6 |

Measured with `bundle exec rake bench` (2,000 transactions each, one thread, Ruby 4.0.10, Rails 8.1.4, MySQL 9.7 on the same Apple M2 laptop, `innodb_flush_log_at_trx_commit=1`, `sync_binlog=1`):

| Scenario | Mean | p50 | p99 | Transactions/s |
|---|---:|---:|---:|---:|
| One database, plain transaction | 0.18 ms | 0.16 ms | 0.47 ms | 5,416 |
| Two databases, nested plain transactions (not atomic) | 0.35 ms | 0.33 ms | 0.74 ms | 2,838 |
| ActiveXA, one database touched | 0.23 ms | 0.21 ms | 0.69 ms | 4,347 |
| ActiveXA, two databases | 0.87 ms | 0.82 ms | 1.53 ms | 1,149 |

In short: atomicity across two databases costs about half a millisecond per transaction here, and a transaction that only touches one database costs almost nothing extra. On Linux servers, where each flush reaches stable storage, the gap grows with your storage's fsync latency, since ActiveXA does three times as many. Run the benchmark on your own hardware before relying on these numbers.

## How it works

1. A normal Rails transaction is opened on each database, but the adapter issues `XA START` instead of `BEGIN`, lazily, when the database is first queried.
2. Your block runs.
3. While all the transactions are still open, ActiveXA runs `before_commit` callbacks, then `XA END` and `XA PREPARE` on every database. Each database has now promised it can commit.
4. A commit decision is written to the decision log on a separate connection. This is the point of no return.
5. `XA COMMIT` runs on every database, then the decision is deleted.
6. `after_commit` callbacks run.

Recovery resolves anything a crash leaves prepared: a branch whose transaction has a logged decision is committed, one without is rolled back. Before rolling back, recovery writes an abort marker, so a coordinator that turns out to be alive cannot commit afterwards. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the details.

## What it does not do

- **No isolation across databases.** Between the first and last `XA COMMIT` (normally microseconds), a reader can see one database's new data without the other's.
- **Locks wait for recovery.** A prepared branch holds its row locks until it is resolved. If a database becomes unreachable after `PREPARE`, those rows stay locked until recovery runs, so run it often.
- **No DDL inside the block.** MySQL does not allow implicit commits in an XA transaction.
- **ActiveXA must open the outermost transaction** on every participant; it raises `TransactionAlreadyOpen` otherwise. That also means transactional tests cannot wrap ActiveXA code: use truncation for those tests.

## Requirements

- MySQL 8.0.30 or later with InnoDB, row-based or mixed binary logging, and no replication filters on the tables involved.
- Rails 8.1 with `mysql2` (Trilogy is hooked the same way but untested).
- Ruby 4.0 or later.
- The recovery user needs the `XA_RECOVER_ADMIN` privilege. Check that your managed host allows external XA.
- The decision log takes a second connection from its pool for a moment at each two-database commit. Size that pool for it.

## Documentation

- [Architecture](docs/ARCHITECTURE.md): the commit protocol, recovery, clocks and failure handling
- [Install & setup](docs/INSTALL.md): setup in an app, and working on the gem
- [Usage](docs/USAGE.md): configuration, errors and the recovery report
- [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

## Development

```sh
bin/setup                 # bundle install, create xa_primary / xa_tracker and the xa user
bundle exec rake          # tests, against a real MySQL server
bundle exec rubocop
bundle exec rake bench    # the benchmark above
```

Point the tests at another server with `MYSQL_HOST`, `MYSQL_TCP_PORT`, `MYSQL_USER` and `MYSQL_PASSWORD`. Set `SQL_LOG=1` to see the XA statements. The tests drop tables and roll back every prepared XA branch they can see, so never run them against a server with data you care about.

## License

[MIT](LICENSE), © 2026 Vlad Radulescu, Studio51 Solutions.
