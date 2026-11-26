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
  c.abort_retention = 24 * 60 * 60       # seconds
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

### The decision log needs a connection of its own

The decision is written on a second connection from the decision log's pool while the transaction's own connections are still checked out. If the log lives in a participant's pool, every transaction that commits on two databases needs two connections from that pool for a moment.

- Size that pool for it, or give the log a pool of its own: an abstract class with its own `connects_to` entry pointing at the same database.
- With a pool of one, a transaction that touches both databases waits for `checkout_timeout`, rolls back and raises `DecisionLogFailed`. One that touches a single database still commits, since it needs no log.
- When the pool is exhausted under load the same thing happens to whichever transactions cannot get the extra connection. Nothing is left half done, but they fail.

## How it works

1. A normal Rails transaction is opened on each database, but the adapter issues `XA START` instead of `BEGIN`, lazily, when the database is first queried.
2. Your block runs.
3. While all the Rails transactions are still open, ActiveXA runs `before_commit` callbacks, including those of records that another database's callbacks save, then `XA END` and `XA PREPARE` on every database. Each database has now promised it can commit.
4. A commit decision is written to the decision log on a separate connection. This is the point of no return.
5. `XA COMMIT` runs on every database, then the decision row is deleted.
6. The Rails blocks exit. Their `COMMIT` is a no-op.
7. `after_commit` callbacks run, once the data is durable on every database and every connection is an ordinary one again. They can write to any of the databases, or start another ActiveXA transaction.

If only one database was touched, ActiveXA uses `XA COMMIT ... ONE PHASE` and skips the log.

## What it guarantees

Before the decision is logged, any failure rolls back every database and raises (`PrepareFailed`, `DecisionLogFailed`, or your block's own exception). `after_rollback` callbacks fire once every database has rolled back.

After the decision is logged, the transaction is committed, even if a database fails to apply `XA COMMIT`. ActiveXA does not raise in that case, because a caller retrying would duplicate work. The failed branch stays `PREPARED`, the connection holding it is discarded, `on_incomplete_commit` is called, and `ActiveXA.recover!` commits it.

Nothing rolls a branch back once the decision may be in the log. If an exception is raised into the thread at that point (a request timeout, an interrupt) or the thread is killed, the branches that have not committed yet stay `PREPARED` for recovery; they are not undone alongside ones that already committed. `after_commit` callbacks still run, because the data is committed.

If writing the decision fails, ActiveXA asks the log which way it went, since a row can be written and its acknowledgement lost. If the decision turns out to be there, the commit goes ahead. If it is not, everything is rolled back and `DecisionLogFailed` is raised. If the log cannot be reached to ask, ActiveXA raises `OutcomeUnknown`, rolls nothing back and runs no commit or rollback callbacks: the branches stay `PREPARED` and recovery finishes the transaction whichever way the log says.

If the process dies mid-transaction, recovery uses presumed abort: a prepared branch with a logged commit decision is committed, and one without is rolled back. Before rolling back, recovery writes an abort marker for the transaction into the decision log. A marker and a commit decision cannot both exist, so if the coordinator turns out to be alive after all (the transaction may simply have run for longer than the grace period), its commit is refused and it rolls back too, raising `DecisionLogFailed`. Branches younger than the grace period are left alone so that recovery does not abort transactions that are merely still running.

## What it does not guarantee

**Isolation across databases.** Two-phase commit gives atomicity, not a global snapshot. Between the first and last `XA COMMIT` (normally microseconds; longer if a commit is in doubt), another reader can see the primary's new data without the tracker's.

**Availability under failure.** A prepared branch holds its row locks until it's resolved. If a database is unreachable after PREPARE, those rows stay locked until recovery runs. Run recovery frequently.

**A shared transaction on a shared server.** Two databases on the same MySQL server still get two separate branches. MySQL treats them as unrelated transactions: neither sees the other's uncommitted changes, and if both touch the same row (through a cross-database query, a trigger or a foreign key) the second waits for the first until it hits `innodb_lock_wait_timeout`.

## Clocks, the grace period and long transactions

The grace period is measured from when a transaction started. That time is part of its XID and comes from the clock of the app server that began it; recovery compares it with the clock of the host it runs on. Keep those clocks in step (NTP is plenty) and the grace period well above any drift between them.

Neither clock drift nor a slow transaction can split a transaction across databases, because the decision log has the last word. What they can do is get a healthy transaction aborted: if recovery looks at a transaction older than the grace period at the moment its branches are prepared but its decision is not yet written, it rolls it back and the coordinator raises `DecisionLogFailed`. That window is a few milliseconds per transaction, so it takes a transaction that outlives the grace period and some bad luck. Set `recovery_grace_period` above your longest transaction if you would rather it never happened; the cost is that branches orphaned by a crash hold their locks for that long.

`abort_retention` is how long recovery keeps the abort marker it writes when it rolls a transaction back. The marker is what refuses a late commit from that transaction's coordinator, so it must outlast any pause a coordinator could survive. The default is a day. The rows are tiny and only appear when recovery aborts something.

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

Set `SQL_LOG=1` to see the XA statements. To use a server on another port, set `MYSQL_HOST=127.0.0.1 MYSQL_TCP_PORT=3307`.
