# frozen_string_literal: true

module ActiveXA

  # Base class of every error ActiveXA raises.
  #
  class Error < StandardError; end

  # ActiveXA is not configured, e.g. no decision log class is set.
  #
  class ConfigurationError < Error; end

  # A participant connection already had an open transaction, so it cannot be enlisted.
  # XA START cannot join an existing local transaction.
  #
  class TransactionAlreadyOpen < Error; end

  # Phase one failed on some database, or a one-phase commit failed.
  # Everything was rolled back.
  #
  class PrepareFailed < Error; end

  # The commit decision could not be written, or recovery had already aborted the transaction.
  # Everything was rolled back.
  #
  class DecisionLogFailed < Error; end

  # The commit decision may or may not have reached the log, and the log could not be asked.
  # Nothing was rolled back: the branches stay prepared and recovery finishes the transaction whichever way the log says.
  #
  class OutcomeUnknown < Error; end

  # Something tried to use a connection in a way XA does not allow, e.g. reopening a finished branch.
  #
  class UnsupportedOperation < Error; end
end
