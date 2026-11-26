# frozen_string_literal: true

# A sale, in the shop database. Its money side lives in the ledger.
class Order < ApplicationRecord
  belongs_to :product

  # Runs only once the order and its ledger entry are durable in both databases.
  after_create_commit { Rails.logger.info("receipt for order #{ id }: ledger entry #{ LedgerEntry.where(order_id: id).pick(:id) }") }

  # The ledger entry recording this order, from the other database.
  def ledger_entry
    LedgerEntry.find_by(order_id: id)
  end
end
