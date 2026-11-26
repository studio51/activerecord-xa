# frozen_string_literal: true

module ActiveXA
  class Error < StandardError; end
  class ConfigurationError < Error; end

  # A participant connection already had an open transaction, so it can't be
  # enlisted (XA START can't join an existing local transaction).
  class TransactionAlreadyOpen < Error; end

  # Phase 1 failed on some database. Everything was rolled back.
  class PrepareFailed < Error; end

  # The commit decision couldn't be written. Everything was rolled back.
  class DecisionLogFailed < Error; end

  # Something tried to use a connection in a way XA doesn't allow.
  class UnsupportedOperation < Error; end
end
