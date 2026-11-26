# frozen_string_literal: true

# Shows both databases side by side, with anything ActiveXA is in the middle of.
class DashboardController < ApplicationController
  def show
    @products = Product.for_sale.order(:id)
    @orders = Order.includes(:product).order(id: :desc).limit(15)
    @ledger_entries = LedgerEntry.order(id: :desc).limit(15)

    order_ids = Order.pluck(:id)
    entry_order_ids = LedgerEntry.pluck(:order_id)
    @orders_without_entry = (order_ids - entry_order_ids).size
    @entries_without_order = (entry_order_ids - order_ids).size
    @recorded = entry_order_ids.to_set

    @prepared = prepared_branches
    @decisions = ApplicationRecord.connection.select_all(
      "SELECT gtrid, outcome, participants, created_at FROM #{ ActiveXA::DecisionLog::TABLE } ORDER BY created_at DESC"
    ).to_a
  end

  private
    # Prepared XA branches on the server, as recovery would see them.
    def prepared_branches
      ApplicationRecord.connection.select_rows("XA RECOVER").filter_map do |format_id, gtrid_length, _bqual_length, data|
        next unless format_id.to_i == ActiveXA::Xid::FORMAT_ID

        gtrid = data.byteslice(0, gtrid_length.to_i)
        { gtrid:, branch: data.byteslice(gtrid_length.to_i..), age: (Time.now - ActiveXA::Xid.created_at(gtrid)).round }
      end
    end
end
