# frozen_string_literal: true

# The money side of an order, in the separate ledger database.
class LedgerEntry < LedgerRecord
  # The order this entry records, from the shop database.
  def order
    Order.find_by(id: order_id)
  end
end
