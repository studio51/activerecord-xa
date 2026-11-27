# frozen_string_literal: true

# Runs ActiveRecord::XA.recover!, as a scheduled job would.
class RecoveriesController < ApplicationController
  def create
    report = ActiveRecord::XA.recover!
    summary = "Recovery committed #{ report.committed.size }, rolled back #{ report.rolled_back.size }, " \
              "skipped #{ report.skipped.size } (too young), pruned #{ report.pruned.size } decisions"
    summary += ", errors: #{ report.errors.map { |subject, error| "#{ subject }: #{ error.message }" }.join("; ") }" if report.errors.any?

    redirect_to root_path, notice: "#{ summary }."
  end
end
