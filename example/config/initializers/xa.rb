# frozen_string_literal: true

# ActiveRecord::XA: atomic transactions across MySQL databases.
#
ActiveRecord::XA.configure do |config|
  # The decision log lives in the shop database.
  config.decision_log_class = "ApplicationRecord"

  # Both databases take part, so recovery looks at both.
  config.participants = %w[ApplicationRecord LedgerRecord]

  # A demo wants recovery to act within seconds of a simulated crash.
  # Production apps should leave this at a minute or more.
  config.recovery_grace_period = 5

  config.on_incomplete_commit = ->(gtrid, failures) { Rails.logger.error("XA in doubt: #{ gtrid } (#{ failures.size } branch)") }
  config.logger = Rails.logger
end
