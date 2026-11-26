# ActiveXA

Atomic transactions across multiple MySQL databases in Rails, using MySQL's XA two-phase commit, with a durable decision log and crash recovery.

Nested `transaction` blocks on different databases look atomic, but they're two independent transactions. The inner one commits when its block exits, so a failure afterwards leaves it committed and the outer one rolled back. ActiveXA makes them commit together or not at all.

```ruby
ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
  persist_tracker_data!
  persist_application_data!
end
```

Inside the block you use models exactly as normal. Only databases the block actually touches join the transaction.

## Setup

```ruby
# config/initializers/active_xa.rb
ActiveXA.configure do |c|
  c.decision_log_class = PrimaryRecord   # where the decision log table lives
  c.recovery_grace_period = 60           # seconds
  c.on_incomplete_commit = ->(gtrid, failures) { Sentry.capture_message("XA in doubt: #{gtrid}") }
end
```

Create the decision log table (a migration on the decision log database):

```ruby
execute ActiveXA::DecisionLog.create_table_sql
```

Run recovery on a schedule, passing every class that takes part in ActiveXA transactions:

```ruby
ActiveXA.recover!(PrimaryRecord, TrackerRecord)
```

## How it works

1. A normal Rails transaction is opened on each database, but the adapter issues `XA START` instead of `BEGIN`, lazily, when the database is first queried.
2. Your block runs.
3. While all the Rails transactions are still open, ActiveXA runs `before_commit` callbacks, then `XA END` and `XA PREPARE` on every database. Each database has now promised it can commit.
4. A commit decision is written to the decision log on a separate connection. This is the point of no return.
5. `XA COMMIT` runs on every database, then the decision row is deleted.
6. The Rails blocks exit. Their `COMMIT` is a no-op, so `after_commit` callbacks fire only once the data is durable on every database.

If only one database was touched, ActiveXA uses `XA COMMIT ... ONE PHASE` and skips the log.

## What it guarantees

Before the decision is logged, any failure rolls back every database and raises (`PrepareFailed`, `DecisionLogFailed`, or your block's own exception). `after_rollback` callbacks fire as normal.

After the decision is logged, the transaction is committed, even if a database fails to apply `XA COMMIT`. ActiveXA does not raise in that case, because a caller retrying would duplicate work. The failed branch stays `PREPARED`, the connection holding it is discarded, `on_incomplete_commit` is called, and `ActiveXA.recover!` commits it.

If the process dies mid-transaction, recovery uses presumed abort: a prepared branch with a logged decision is committed, and one without is rolled back. Branches younger than the grace period are left alone so recovery never races a live coordinator.

## What it does not guarantee

**Isolation across databases.** Two-phase commit gives atomicity, not a global snapshot. Between the first and last `XA COMMIT` (normally microseconds; longer if a commit is in doubt), another reader can see the primary's new data without the tracker's.

**Availability under failure.** A prepared branch holds its row locks until it's resolved. If a database is unreachable after PREPARE, those rows stay locked until recovery runs. Run recovery frequently.

## Requirements and limitations

- MySQL 8.0.30 or later with InnoDB. Earlier versions can leave XA state and the binary log inconsistent after a crash.
- Row-based or mixed binary logging, and no replication filters on these tables.
- The recovery user needs the `XA_RECOVER_ADMIN` privilege. Check your managed host allows external XA.
- Tested against Rails 8.1 with `mysql2`. It hooks undocumented adapter internals (`internal_execute`, the transaction stack), so each Rails minor version needs testing before support is declared.
- ActiveXA must open the outermost transaction on every participant. It raises `TransactionAlreadyOpen` otherwise, which also means transactional tests can't wrap ActiveXA code. Use truncation for those tests.
- No DDL inside the block (MySQL implicit commits aren't allowed in XA).
- `XA RECOVER` is server-wide. Recovery de-duplicates branches when participants share a server.

## Running the tests

Tests run against a real MySQL server with two databases, `xa_primary` and `xa_tracker`:

```sh
MYSQL_USER=xa MYSQL_PASSWORD=xa bundle exec rake
```

Set `SQL_LOG=1` to see the XA statements.
