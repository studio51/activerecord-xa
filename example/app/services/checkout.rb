# frozen_string_literal: true

# Sells a product: takes it out of stock and creates the order in the shop
# database, records the money in the ledger database, then charges the card.
#
#   Checkout.new(product).call                              # ActiveRecord::XA: all or nothing
#   Checkout.new(product, decline: true).call               # card declined: nothing is kept
#   Checkout.new(product, decline: true, atomic: false).call  # plain nested transactions: the ledger keeps an orphan
#
class Checkout
  class PaymentDeclined < StandardError; end

  def initialize(product, decline: false, atomic: true)
    @product = product
    @decline = decline
    @atomic = atomic
  end

  def call
    if @atomic
      ActiveRecord::XA.transaction(ApplicationRecord, LedgerRecord) do
        record_sale.tap { charge_card }
      end
    else
      # What Rails gives you without ActiveRecord::XA: two independent transactions.
      # The ledger's commits as soon as its block exits, before the card is charged.
      ApplicationRecord.transaction do
        LedgerRecord.transaction { record_sale }.tap { charge_card }
      end
    end
  end

  private
    def record_sale
      @product.lock!
      @product.update!(stock: @product.stock - 1)

      order = Order.create!(product: @product, quantity: 1, total_cents: @product.price_cents)
      LedgerEntry.create!(order_id: order.id, amount_cents: order.total_cents, note: "sale of #{ @product.name }")

      order
    end

    def charge_card
      raise PaymentDeclined, "the card was declined" if @decline
    end
end
