# Architecture

> How ActiveRecord::XA is put together, and why.

## Overview

Rails runs one transaction per database connection. Nesting `transaction` blocks for two databases gives two independent transactions: the inner one commits when its block exits, so a failure afterwards leaves one database changed and the other not.

ActiveRecord::XA turns those transactions into branches of one global transaction using MySQL's XA, an implementation of two-phase commit. Every branch first promises it can commit (`XA PREPARE`). Only when all have promised is the decision to commit written down, and only then is each branch committed. A crash at any point leaves enough behind for a recovery run to finish the job the same way on every database.

## Structure

```
lib/
  activerecord-xa.rb                   lets Bundler require the gem by its name
  active_record/xa.rb                  entrypoint: ActiveRecord::XA.transaction, .recover!, .configure, load hooks
  active_record/xa/configuration.rb    settings
  active_record/xa/coordinator.rb      runs one global transaction: enlist, prepare, decide, commit
  active_record/xa/branch.rb           one database's XA state machine
  active_record/xa/xid.rb              XA transaction identifiers
  active_record/xa/decision_log.rb     the durable commit / abort decisions
  active_record/xa/recovery.rb         resolves prepared branches left behind
  active_record/xa/adapter_extension.rb      reroutes BEGIN / COMMIT / ROLLBACK on enlisted connections
  active_record/xa/transaction_extension.rb  lets the coordinator time Rails' transactional callbacks
  active_record/xa/railtie.rb          the xa:recover rake task
  generators/xa/install/               initializer and migration generator
test/                                  Minitest, against a real MySQL server
benchmark/transactions.rb              per-transaction cost
```

## The commit protocol

1. **Enlist.** The coordinator opens a normal Rails transaction on each participant, outermost first, with the connection enlisted. The adapter extension turns Rails' `BEGIN` into `XA START`. Rails begins transactions lazily, so a database the block never queries never starts a branch.
2. **Run the block.** Models are used as normal. Savepoints work inside an XA branch.
3. **before_commit.** Still inside every transaction, the coordinator runs `before_commit` callbacks, innermost database first, as nested Rails transactions would. A callback may write to any database; a branch that gains records after its turn gets another pass.
4. **Prepare.** `XA END` and `XA PREPARE` on every started branch. If only one branch started, it commits with `XA COMMIT ... ONE PHASE` instead and the protocol stops here.
5. **Decide.** The commit decision is inserted into the decision log on a separate connection. From the moment that insert is sent, every branch is marked in doubt: nothing in this process will roll it back.
6. **Commit.** `XA COMMIT` on every branch, then the decision row is deleted.
7. **Callbacks.** The Rails blocks exit (their `COMMIT` is a no-op), every connection is de-enlisted, and only then do `after_commit` callbacks run, innermost database first.

Any failure before step 5 rolls back every branch. A failure after it is reported (`on_incomplete_commit`), not raised, because the transaction is committed and a caller retrying would duplicate the work. A branch that could not be committed stays prepared, its connection is closed so the server detaches it, and recovery commits it.

## The decision log

One row per global transaction, keyed by its gtrid, with an outcome of `commit` or `abort`. The primary key is what keeps every party consistent: whoever writes a decision first wins, and the others find it and follow.

- The coordinator writes `commit` after every branch has prepared.
- Recovery writes `abort` before rolling back a prepared branch that has no decision (presumed abort).
- A coordinator whose commit insert fails cannot tell whether the row was written, so it asks for `abort` itself. If the primary key refuses, the commit row is there and it commits; otherwise it rolls back and raises `DecisionLogFailed`. If the log cannot be reached at all, it raises `OutcomeUnknown` and leaves the branches prepared for recovery.
- If no connection to the log could even be checked out, the insert was never sent, so the coordinator rolls back straight away.

The log is written on a connection checked out separately from its pool, so it is never part of the XA transaction, even when the table lives in a participant's database. That connection is the second one each two-database commit takes from the log's pool, for a moment. Size the pool for it, or give the log a pool of its own (an abstract class with its own `connects_to` entry pointing at the same database). With an exhausted pool the transaction rolls back with `DecisionLogFailed`; nothing is left half done.

## Recovery

`ActiveRecord::XA.recover!` lists prepared branches with `XA RECOVER` on each participant and resolves those older than the grace period:

- a logged `commit`: `XA COMMIT`
- no decision: write `abort`, then `XA ROLLBACK`

Each gtrid is settled once per run, so every branch of a transaction gets the same answer.

`XA RECOVER` is server-wide: participants that share a server see each other's branches, and recovery de-duplicates them. It also sees branches of any other application using the server. Every gtrid carries a namespace derived from the name of the database the decision log lives in, and recovery only touches its own. Two installations that share a server and keep their logs in databases of the same name need a `config.namespace` each.

A database that is down, or whose user lacks `XA_RECOVER_ADMIN`, is reported in `report.errors` and does not hold up the others.

Recovery then prunes finished decisions:

- A `commit` decision is deleted once no branch of it is still prepared and the row is older than the grace period, measured on the log database's own clock.
- An `abort` marker is kept for `abort_retention` (a day by default), so that a stalled coordinator that wakes up still finds its commit refused.
- A decision is only pruned by a run that was given every database the transaction used. Recovering a subset, or one shard at a time, is safe; decisions involving the other databases stay until a run covers them.

## Clocks, the grace period and long transactions

The grace period is measured from when a transaction started. That time is part of its XID and comes from the clock of the app server that began it; recovery compares it with the clock of the host it runs on. Keep those clocks in step (NTP is plenty) and the grace period well above any drift between them.

Neither clock drift nor a slow transaction can split a transaction across databases, because the decision log has the last word. What they can do is get a healthy transaction aborted: if recovery looks at a transaction older than the grace period in the few milliseconds between its branches preparing and its decision being written, it rolls it back and the coordinator raises `DecisionLogFailed`. Set `recovery_grace_period` above your longest transaction if you would rather that never happened; the cost is that branches orphaned by a crash hold their locks for that long.

## Interrupts and killed threads

Ruby can raise into a thread at any point (a request timeout, an interrupt) or kill it. Before the decision is sent, that rolls everything back, as in Rails. After it, nothing is rolled back: branches that have not committed yet stay prepared for recovery, and `after_commit` callbacks still run, because the data is committed. When the outcome is genuinely unknown, neither `after_commit` nor `after_rollback` runs, as in Rails when a `COMMIT`'s connection is lost.

## Key decisions

- **Presumed abort.** Only commit decisions need to be durable before acting; anything undecided is rolled back. This keeps the common path to one log insert and one delete per transaction.
- **The log arbitrates, not the clock.** The grace period only avoids disturbing transactions that are still running. Correctness comes from the primary key on the decision log.
- **Rails stays in charge of the block.** ActiveRecord::XA reroutes three adapter methods and times four transaction hooks; everything else inside the block is ordinary Active Record. The price is coupling to Active Record internals (`internal_execute`, the transaction stack), so each Rails minor version is tested before the gemspec allows it.
- **Lazy enlistment.** A database joins only when queried, which makes ActiveRecord::XA nearly free when a block touches one database. With lazy transactions switched off on a connection (calling `raw_connection` does that for good), its branch starts when the transaction opens and always takes part in the two-phase commit.
- **Separate branches on a shared server.** Two databases on the same MySQL server still get two branches. MySQL treats them as unrelated transactions: neither sees the other's uncommitted changes, and if both touch the same row the second waits for the first until `innodb_lock_wait_timeout`.
