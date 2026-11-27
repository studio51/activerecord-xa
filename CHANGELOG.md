# Changelog

All notable changes to ActiveRecord::XA are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-11-27

First release.

### Added
- `ActiveRecord::XA.transaction`: one transaction across several MySQL databases, using XA two-phase commit, with Rails callbacks, savepoints, isolation levels and `ActiveRecord::Rollback` working as in a normal transaction.
- A durable decision log and `ActiveRecord::XA.recover!`, which commits or rolls back whatever a crash leaves prepared, the same way on every database.
- `config.participants`, so `ActiveRecord::XA.recover!` needs no arguments, and the `xa:recover` rake task.
- `bin/rails generate xa:install`, writing the initializer and the decision log migration.
- Class names accepted for `decision_log_class` and `participants`, so initializers never load models.
- A benchmark of the per-transaction cost (`rake bench`).
- An example Rails app (`example/`): a shop and a ledger in two databases, with buttons for declined cards, crashes mid-commit and recovery.

[Unreleased]: https://github.com/studio51/activerecord-xa/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/studio51/activerecord-xa/releases/tag/v0.1.0
