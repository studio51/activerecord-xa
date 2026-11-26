# Changelog

All notable changes to ActiveXA are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `ActiveXA.transaction`: one transaction across several MySQL databases, using XA two-phase commit, with Rails callbacks, savepoints, isolation levels and `ActiveRecord::Rollback` working as in a normal transaction.
- A durable decision log and `ActiveXA.recover!`, which commits or rolls back whatever a crash leaves prepared, the same way on every database.
- `config.participants`, so `ActiveXA.recover!` needs no arguments, and the `active_xa:recover` rake task.
- `bin/rails generate active_xa:install`, writing the initializer and the decision log migration.
- Class names accepted for `decision_log_class` and `participants`, so initializers never load models.
- A benchmark of the per-transaction cost (`rake bench`).

[Unreleased]: https://github.com/studio51/activerecord-xa/commits/main
