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

    # Recovery leaves branches younger than this alone, so it does not abort
    # a transaction that is simply still running. Seconds, counted from when
    # the transaction started.
    attr_accessor :recovery_grace_period

    # How long recovery keeps the "abort" marker it writes when it rolls back
    # an undecided transaction. The marker is what stops that transaction's
    # coordinator, should it still be alive, from committing afterwards, so
    # this must be longer than any coordinator could stall. Seconds.
    attr_accessor :abort_retention

    # Recovery only resolves transactions that carry its own namespace, so
    # that it never touches those of another ActiveXA installation using the
    # same MySQL servers. It defaults to the name of the decision log's
    # database. Set it if two installations that share a server keep their
    # logs in databases of the same name.
    attr_accessor :namespace

    # Called as ->(gtrid, failures) when the commit decision was logged but
    # one or more databases failed to apply XA COMMIT. The transaction counts
    # as committed; recovery completes the stragglers.
    attr_accessor :on_incomplete_commit

    attr_accessor :logger

    def initialize
      @recovery_grace_period = 60
      @abort_retention = 24 * 60 * 60
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
      Recovery.new(record_classes, log: decision_log, grace: config.recovery_grace_period,
                                   abort_retention: config.abort_retention).run
    end

    def decision_log
      klass = config.decision_log_class or
        raise ConfigurationError, "set ActiveXA.config.decision_log_class"
      DecisionLog.new(klass.connection_pool, namespace: config.namespace)
    end
  end
end

ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter.prepend(ActiveXA::AdapterExtension)
ActiveRecord::ConnectionAdapters::Transaction.prepend(ActiveXA::TransactionExtension)
