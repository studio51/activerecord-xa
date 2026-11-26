# frozen_string_literal: true

require "active_record"

require_relative "active_xa/version"
require_relative "active_xa/errors"
require_relative "active_xa/configuration"
require_relative "active_xa/xid"
require_relative "active_xa/branch"
require_relative "active_xa/adapter_extension"
require_relative "active_xa/transaction_extension"
require_relative "active_xa/decision_log"
require_relative "active_xa/coordinator"
require_relative "active_xa/recovery"
require_relative "active_xa/railtie" if defined?(Rails::Railtie)

# Atomic transactions across multiple MySQL databases for Active Record, using MySQL XA two-phase commit.
#
#   ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
#     persist_tracker_data!
#     persist_application_data!
#   end
#
# Either every database commits or none does.
# If the process dies between PREPARE and COMMIT, ActiveXA.recover! finishes the job from the decision log.
#
module ActiveXA

  class << self

    # The current configuration.
    #
    # @return [Configuration] the configuration
    def config
      @config ||= Configuration.new
    end

    # Changes the configuration.
    #
    # @yieldparam config [Configuration] the configuration
    # @return [void]
    def configure
      yield config
    end

    # Runs the block as one transaction across every database the classes connect to.
    # Inside the block, use models exactly as normal; only databases the block touches join.
    #
    # @param record_classes [Array<Class>] Active Record classes covering at least two databases
    # @yield the work to do
    # @raise [PrepareFailed, DecisionLogFailed, OutcomeUnknown, TransactionAlreadyOpen] see the README
    # @return [Object] the block's value, or nil when it raised ActiveRecord::Rollback
    def transaction(*record_classes, &block)
      raise ArgumentError, "ActiveXA.transaction requires a block" unless block

      Coordinator.new(record_classes, log: decision_log).run(&block)
    end

    # Resolves prepared but unfinished branches left by a crash or a failed commit.
    # Pass every class that takes part in ActiveXA transactions, or set config.participants.
    #
    # @param record_classes [Array<Class>] classes covering every participating database
    # @raise [ConfigurationError] if no classes are given or configured
    # @return [Recovery::Report] what the run did
    def recover!(*record_classes)
      record_classes = config.resolved_participants if record_classes.empty?
      raise ConfigurationError, "pass the participating classes or set ActiveXA.config.participants" if record_classes.empty?

      Recovery.new(record_classes, log: decision_log, grace: config.recovery_grace_period,
                                   abort_retention: config.abort_retention).run
    end

    # The decision log, on the configured class's database.
    #
    # @raise [ConfigurationError] if no decision log class is set
    # @return [DecisionLog] the log
    def decision_log
      DecisionLog.new(config.resolved_decision_log_class.connection_pool, namespace: config.namespace)
    end
  end
end

# Hook into Active Record as it loads, so requiring the gem never loads it early.
#
ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/abstract/transaction"

  ActiveRecord::ConnectionAdapters::Transaction.prepend(ActiveXA::TransactionExtension)
end

ActiveSupport.on_load(:active_record_mysql2adapter) { prepend ActiveXA::AdapterExtension }
ActiveSupport.on_load(:active_record_trilogyadapter) { prepend ActiveXA::AdapterExtension }
