# frozen_string_literal: true

# Sells a product, with or without ActiveRecord::XA, optionally declining the card.
class CheckoutsController < ApplicationController
  SCENARIOS = {
    "atomic" => { decline: false, atomic: true },
    "declined" => { decline: true, atomic: true },
    "naive_declined" => { decline: true, atomic: false }
  }.freeze

  def create
    product = Product.find(params[:product_id])
    order = Checkout.new(product, **SCENARIOS.fetch(params[:scenario])).call

    redirect_to root_path, notice: "Order ##{ order.id } placed: committed in the shop and in the ledger."
  rescue Checkout::PaymentDeclined => e
    outcome = if params[:scenario] == "naive_declined"
      "The shop rolled back, but the ledger had already committed its entry: an orphan."
    else
      "ActiveRecord::XA rolled back both databases."
    end

    redirect_to root_path, alert: "#{ e.message }. #{ outcome }"
  end
end
