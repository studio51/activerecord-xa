# Install & setup

## Requirements

- Ruby 4.0 or later, Rails 8.1.
- MySQL 8.0.30 or later with InnoDB. Earlier versions can leave XA state and the binary log inconsistent after a crash.
- Row-based or mixed binary logging, and no replication filters on the tables ActiveRecord::XA writes.
- The database user that runs recovery needs `XA_RECOVER_ADMIN`. Some managed hosts restrict external XA; check yours.

## In a Rails application

```ruby
# Gemfile
gem "activerecord-xa"
```

```sh
bundle install
bin/rails generate xa:install
bin/rails db:migrate
```

The generator writes:

- `config/initializers/xa.rb`, where you name the decision log's class and the participating classes;
- a migration that creates the `xa_decisions` table. Pass `--database NAME` to put it in another database's migrations path, if the log should live there.

A typical multi-database setup:

```yaml
# config/database.yml
production:
  primary:
    adapter: mysql2
    database: shop
  ledger:
    adapter: mysql2
    database: ledger
    migrations_paths: db/ledger_migrate
```

```ruby
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
  connects_to database: { writing: :primary }
end

class LedgerRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :ledger }
end
```

```ruby
# config/initializers/xa.rb
ActiveRecord::XA.configure do |config|
  config.decision_log_class = "ApplicationRecord"
  config.participants = %w[ApplicationRecord LedgerRecord]
  config.logger = Rails.logger
end
```

Grant the recovery privilege once per server:

```sql
GRANT XA_RECOVER_ADMIN ON *.* TO 'app'@'%';
```

Schedule recovery, every minute is a good default: `bin/rails xa:recover` from cron, or a Solid Queue recurring task with `command: "ActiveRecord::XA.recover!"`.

### Testing an application that uses ActiveRecord::XA

ActiveRecord::XA must open the outermost transaction on every participant, so code that calls it cannot run inside Rails' transactional tests. Turn them off for those tests and clean up by truncation:

```ruby
class TransferTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown { [ Account, LedgerEntry ].each(&:delete_all) }
end
```

## Working on the gem

The tests run against a real MySQL server with two databases, `xa_primary` and `xa_tracker`, and a user `xa` (password `xa`) with `XA_RECOVER_ADMIN`.

```sh
git clone https://github.com/studio51/activerecord-xa.git && cd activerecord-xa
bin/setup                # bundle install, then create the databases and the user as root
bundle exec rake         # tests
bundle exec rubocop      # lint
bundle exec rake bench   # benchmark
```

`bin/setup` connects as `MYSQL_ROOT_USER` (default `root`, password `MYSQL_ROOT_PASSWORD`). The tests and benchmark read `MYSQL_HOST`, `MYSQL_TCP_PORT`, `MYSQL_USER` and `MYSQL_PASSWORD`.

The tests drop tables and roll back every prepared XA branch they can see. Use a throwaway server, for example:

```sh
docker run -d --name xa-mysql -p 3307:3306 -e MYSQL_ALLOW_EMPTY_PASSWORD=yes mysql:8.4
MYSQL_HOST=127.0.0.1 MYSQL_TCP_PORT=3307 bin/setup
MYSQL_HOST=127.0.0.1 MYSQL_TCP_PORT=3307 bundle exec rake
```
