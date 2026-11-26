# frozen_string_literal: true

# Puts the demo back to its starting state.
class ResetsController < ApplicationController
  def create
    # Resolve anything a crash left behind first: prepared branches hold locks the deletes would wait on.
    ActiveXA::Recovery.new(ActiveXA.config.resolved_participants, log: ActiveXA.decision_log, grace: 0, abort_retention: 0).run

    LedgerEntry.delete_all
    Order.delete_all
    Product.crash_tests.delete_all
    Product.update_all(stock: 20)

    redirect_to root_path, notice: "Reset."
  end
end
