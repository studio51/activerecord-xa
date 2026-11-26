# frozen_string_literal: true

# Runs every scenario the dashboard offers and checks the outcome. CI runs it:
#
#   bin/rails db:prepare && bin/rails runner script/smoke.rb
#
def check(label, condition)
  abort "FAIL: #{ label }" unless condition

  puts "ok: #{ label }"
end

def consistent?
  Order.pluck(:id).sort == LedgerEntry.pluck(:order_id).sort
end

def prepared
  ApplicationRecord.connection.select_rows("XA RECOVER").count { |row| row[0].to_i == ActiveRecord::XA::Xid::FORMAT_ID }
end

LedgerEntry.delete_all
Order.delete_all
product = Product.for_sale.first

Checkout.new(product).call
check "ActiveRecord::XA commits both databases", Order.count == 1 && consistent?

begin
  Checkout.new(product.reload, decline: true).call
rescue Checkout::PaymentDeclined
end
check "ActiveRecord::XA rolls both back when the card is declined", Order.count == 1 && consistent?

begin
  Checkout.new(product.reload, decline: true, atomic: false).call
rescue Checkout::PaymentDeclined
end
check "plain nested transactions leave an orphan ledger entry", Order.count == 1 && LedgerEntry.count == 2

%w[after_decision before_decision].each do |stage|
  system(Rails.root.join("bin/rails").to_s, "runner", "script/crash_mid_commit.rb", stage)
end
check "both crashes leave prepared branches", prepared == 4

sleep ActiveRecord::XA.config.recovery_grace_period + 1
report = ActiveRecord::XA.recover!
check "recovery commits the decided crash and rolls back the other", report.committed.size == 2 && report.rolled_back.size == 2
check "nothing is left prepared", prepared.zero?
