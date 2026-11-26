# frozen_string_literal: true

require "active_record"

require_relative "xa/version"
require_relative "xa/errors"
require_relative "xa/configuration"
require_relative "xa/xid"
require_relative "xa/branch"
require_relative "xa/adapter_extension"
require_relative "xa/transaction_extension"
require_relative "xa/decision_log"
require_relative "xa/coordinator"
require_relative "xa/recovery"
require_relative "xa/railtie" if defined?(Rails::Railtie)

# Atomic transactions across multiple MySQL databases for Active Record, using MySQL XA two-phase commit.
#
#   ActiveRecord::XA.transaction(PrimaryRecord, TrackerRecord) do
#     persist_tracker_data!
#     persist_application_data!
#   end
#
# Either every database commits or none does.
# If the process dies between PREPARE and COMMIT, ActiveRecord::XA.recover! finishes the job from the decision log.
#
module ActiveRecord::XA

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
      raise ArgumentError, "ActiveRecord::XA.transaction requires a block" unless block

      Coordinator.new(record_classes, log: decision_log).run(&block)
    end

    # Resolves prepared but unfinished branches left by a crash or a failed commit.
    # Pass every class that takes part in ActiveRecord::XA transactions, or set config.participants.
    #
    # @param record_classes [Array<Class>] classes covering every participating database
    # @raise [ConfigurationError] if no classes are given or configured
    # @return [Recovery::Report] what the run did
    def recover!(*record_classes)
      record_classes = config.resolved_participants if record_classes.empty?
      raise ConfigurationError, "pass the participating classes or set ActiveRecord::XA.config.participants" if record_classes.empty?

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

  ActiveRecord::ConnectionAdapters::Transaction.prepend(ActiveRecord::XA::TransactionExtension)
end

ActiveSupport.on_load(:active_record_mysql2adapter) { prepend ActiveRecord::XA::AdapterExtension }
ActiveSupport.on_load(:active_record_trilogyadapter) { prepend ActiveRecord::XA::AdapterExtension }
