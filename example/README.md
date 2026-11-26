# ActiveRecord::XA example: a shop and a ledger

A small Rails 8.1 app that sells products from one MySQL database (the **shop**) and records the money in another (the **ledger**). One page lets you try every case side by side and watch whether the two databases stay in step.

| Button | What happens |
|---|---|
| **Buy (ActiveRecord::XA)** | Stock, order and ledger entry commit together. |
| **Buy, card declined (ActiveRecord::XA)** | The card is declined after both databases were written. Both roll back. |
| **Buy, card declined (plain nested transactions)** | The same, without ActiveRecord::XA. The ledger had already committed when the card was declined, so it keeps an entry for an order that does not exist. The consistency banner turns red. |
| **Kill a checkout after the commit decision** | A separate process prepares both databases, logs the decision and is killed. Both branches sit prepared, holding their locks. |
| **Kill a checkout before the commit decision** | The same, killed just before the decision is logged. |
| **Run recovery** | `ActiveRecord::XA.recover!`: commits the first crash, rolls back the second. Branches younger than the grace period (5 seconds here) are skipped. |

## Run it

You need Ruby 4.0 and a MySQL 8.0.30+ server you can create databases on, with a user that has `XA_RECOVER_ADMIN` (root does).

```sh
cd example
bundle install
MYSQL_HOST=127.0.0.1 MYSQL_USER=root bin/rails db:prepare
MYSQL_HOST=127.0.0.1 MYSQL_USER=root bin/rails server
```

Open <http://localhost:3000>. `MYSQL_TCP_PORT` and `MYSQL_PASSWORD` are read too. The app creates two databases, `xa_example_shop` and `xa_example_ledger`.

A throwaway server works well:

```sh
docker run -d --name xa-example -p 3307:3306 -e MYSQL_ALLOW_EMPTY_PASSWORD=yes mysql:8.4
MYSQL_HOST=127.0.0.1 MYSQL_TCP_PORT=3307 bin/rails db:prepare
MYSQL_HOST=127.0.0.1 MYSQL_TCP_PORT=3307 bin/rails server
```

## Where to look

- [`config/database.yml`](config/database.yml): the two databases.
- [`app/models/application_record.rb`](app/models/application_record.rb) and [`app/models/ledger_record.rb`](app/models/ledger_record.rb): one abstract class per database.
- [`config/initializers/xa.rb`](config/initializers/xa.rb): written by `bin/rails generate xa:install`, then edited.
- [`app/services/checkout.rb`](app/services/checkout.rb): the same sale with and without ActiveRecord::XA.
- [`app/models/order.rb`](app/models/order.rb): an `after_create_commit` that reads the ledger, safely, because it runs only once both databases have committed.
- [`script/crash_mid_commit.rb`](script/crash_mid_commit.rb): how the crash buttons kill a checkout mid-commit.
- [`app/controllers/recoveries_controller.rb`](app/controllers/recoveries_controller.rb): recovery and its report. In production you would run `bin/rails xa:recover` on a schedule instead.
