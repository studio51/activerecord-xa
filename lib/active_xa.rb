# frozen_string_literal: true

require "active_record"
require "active_record/connection_adapters/abstract_mysql_adapter"
require "active_record/connection_adapters/abstract/transaction"
require "logger"

require_relative "active_xa/version"
require_relative "active_xa/errors"
require_relative "active_xa/xid"
require_relative "active_xa/branch"
require_relative "active_xa/adapter_extension"
require_relative "active_xa/transaction_extension"
require_relative "active_xa/decision_log"
require_relative "active_xa/coordinator"
require_relative "active_xa/recovery"

# Two-phase commit across MySQL databases for Active Record, using MySQL XA.
#
#   ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
#     persist_tracker_data!
#     persist_application_data!
#   end
#
# Either every database commits or none does. If the process dies between
# PREPARE and COMMIT, ActiveXA.recover! finishes the job from the decision log.
module ActiveXA
  class Configuration
    # Abstract record class whose database holds the decision log table.
    # It may be one of the participants: the log is written on a separate
    # connection, outside the XA transaction.
    attr_accessor :decision_log_class

    # Recovery leaves branches younger than this alone, so it never races a
    # coordinator that is still mid-commit.
    attr_accessor :recovery_grace_period

    # Called as ->(gtrid, failures) when the commit decision was logged but
    # one or more databases failed to apply XA COMMIT. The transaction counts
    # as committed; recovery completes the stragglers.
    attr_accessor :on_incomplete_commit

    attr_accessor :logger

    def initialize
      @recovery_grace_period = 60
      @logger = Logger.new($stderr, progname: "ActiveXA")
      @on_incomplete_commit = nil
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def transaction(*record_classes, &block)
      raise ArgumentError, "ActiveXA.transaction requires a block" unless block

      Coordinator.new(record_classes, log: decision_log).run(&block)
    end

    # Resolve prepared-but-unfinished branches. Pass every class that can take
    # part in ActiveXA transactions, so the log can be pruned safely.
    def recover!(*record_classes)
      Recovery.new(record_classes, log: decision_log, grace: config.recovery_grace_period).run
    end

    def decision_log
      klass = config.decision_log_class or
        raise ConfigurationError, "set ActiveXA.config.decision_log_class"
      DecisionLog.new(klass.connection_pool)
    end
  end
end

ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter.prepend(ActiveXA::AdapterExtension)
ActiveRecord::ConnectionAdapters::Transaction.prepend(ActiveXA::TransactionExtension)
