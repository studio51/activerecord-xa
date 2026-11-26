# Usage

## API

### `ActiveRecord::XA.transaction(*record_classes) { ... }`

Runs the block as one transaction across every database the classes connect to. Pass one Active Record class per database (usually the abstract base classes); classes on the same database count once, and at least two databases are required.

Returns the block's value, or `nil` when the block raises `ActiveRecord::Rollback`. Exceptions from the block roll everything back and are re-raised unchanged, so `ActiveRecord::RecordInvalid`, `ActiveRecord::Deadlocked` and friends reach you as usual.

```ruby
result = ActiveRecord::XA.transaction(ApplicationRecord, LedgerRecord) do
  account.update!(balance: account.balance - 10)
  LedgerEntry.create!(account:, amount: -10)
end
```

It must open the outermost transaction on every participant. Calling it inside another transaction on one of them raises `ActiveRecord::XA::TransactionAlreadyOpen`.

### `ActiveRecord::XA.recover!(*record_classes)`

Resolves prepared branches left by a crash or a failed commit, and prunes finished decisions. With no arguments it uses `config.participants`. Returns an `ActiveRecord::XA::Recovery::Report`:

| Field | Contents |
|---|---|
| `committed` | `Xid`s committed because the log says commit |
| `rolled_back` | `Xid`s rolled back because no decision was logged |
| `skipped` | `Xid`s younger than the grace period, left alone |
| `pruned` | gtrids whose decisions were deleted |
| `errors` | `[subject, exception]` pairs; the subject is an `Xid`, a database name, or `:prune` |

Run it regularly: `bin/rails xa:recover` prints a one-line summary and any errors.

### `ActiveRecord::XA.configure { |config| ... }`

| Setting | Default | Meaning |
|---|---|---|
| `decision_log_class` | none, required | Class (or class name) whose database holds the decision log |
| `participants` | `[]` | Classes (or names) covering every participating database, used by `recover!` with no arguments |
| `recovery_grace_period` | `60` | Seconds a transaction must have been running before recovery touches it |
| `abort_retention` | `86400` | Seconds recovery keeps an abort marker, so a stalled coordinator cannot commit late |
| `namespace` | the log database's name | What the XID namespace is derived from; set it when two installations share a server and their logs live in databases of the same name |
| `on_incomplete_commit` | `nil` | Called as `->(gtrid, failures)` when a committed transaction could not apply `XA COMMIT` on some database; `failures` is `[[branch, exception], ...]`. Exceptions from it are logged, not raised |
| `logger` | `Logger.new($stderr)` | Where ActiveRecord::XA reports problems; `nil` silences it |

### `ActiveRecord::XA::DecisionLog.create_table_sql`

The DDL for the decision log table, for a hand-written migration:

```ruby
def up
  execute ActiveRecord::XA::DecisionLog.create_table_sql
end
```

## Errors

Every error inherits from `ActiveRecord::XA::Error`.

| Error | When | State afterwards |
|---|---|---|
| `PrepareFailed` | A database failed `XA PREPARE`, or a one-phase commit failed | Rolled back everywhere |
| `DecisionLogFailed` | The commit decision could not be written, or recovery had already aborted the transaction | Rolled back everywhere |
| `OutcomeUnknown` | The decision may or may not have been written and the log could not be asked | Nothing rolled back; recovery finishes it either way |
| `TransactionAlreadyOpen` | A participant already had an open transaction | Nothing started |
| `ConfigurationError` | No decision log class, or no participants for `recover!` | Nothing started |
| `UnsupportedOperation` | Something tried to reopen a branch that is being committed | |

## Examples

### Several classes on the same database

Classes that share a connection pool count as one participant, so it is fine to pass model classes rather than abstract ones:

```ruby
ActiveRecord::XA.transaction(Order, Invoice, LedgerEntry) { ... }   # Order and Invoice share a database
```

### Isolation levels

`ActiveRecord.default_transaction_isolation_level` applies to every branch. A nested `transaction(isolation:)` behaves as in Rails, which only allows it on the outermost transaction.

### Alerting on incomplete commits

```ruby
ActiveRecord::XA.configure do |config|
  config.on_incomplete_commit = lambda do |gtrid, failures|
    Rails.error.report(ActiveRecord::XA::Error.new("XA in doubt: #{ gtrid }"),
                       context: { branches: failures.map { |branch, error| [ branch.xid.to_s, error.message ] } })
  end
end
```

### Recovery as a job

```ruby
class ActiveRecord::XARecoveryJob < ApplicationJob
  def perform
    report = ActiveRecord::XA.recover!
    report.errors.each { |subject, error| Rails.error.report(error, context: { subject: subject.to_s }) }
  end
end
```
