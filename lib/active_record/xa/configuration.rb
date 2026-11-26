# frozen_string_literal: true

require "logger"

module ActiveRecord::XA

  # Settings for ActiveRecord::XA, set once at boot through ActiveRecord::XA.configure.
  # Classes may be given as names, so an initializer never has to load models.
  #
  class Configuration
    attr_accessor :decision_log_class    # class (or class name) whose database holds the decision log
    attr_accessor :participants          # classes (or class names) covering every database that takes part, for recovery
    attr_accessor :recovery_grace_period # seconds a transaction must have been running before recovery touches it
    attr_accessor :abort_retention       # seconds recovery keeps an abort marker
    attr_accessor :namespace             # overrides the name the XID namespace is derived from
    attr_accessor :on_incomplete_commit  # called as ->(gtrid, failures) when a committed branch could not apply XA COMMIT
    attr_accessor :logger                # where ActiveRecord::XA reports problems, or nil

    # Creates a configuration with the defaults.
    # The grace period of a minute leaves a running transaction alone; the abort retention of a day outlasts any coordinator pause.
    #
    # @return [Configuration] the new configuration
    def initialize
      @decision_log_class = nil
      @participants = []
      @recovery_grace_period = 60
      @abort_retention = 24 * 60 * 60
      @namespace = nil
      @on_incomplete_commit = nil
      @logger = Logger.new($stderr, progname: "ActiveRecord::XA")
    end

    # Resolves the decision log class.
    #
    # @raise [ConfigurationError] if none is set
    # @return [Class] the class
    def resolved_decision_log_class
      resolve(decision_log_class) or raise ConfigurationError, "set ActiveRecord::XA.config.decision_log_class"
    end

    # Resolves the participants.
    #
    # @return [Array<Class>] the classes
    def resolved_participants
      Array(participants).map { |klass| resolve(klass) }
    end

    private

      # Turns a class name into the class, leaving a class as it is.
      #
      # @param klass [Class, String, Symbol, nil] the class or its name
      # @return [Class, nil] the class
      def resolve(klass)
        klass.is_a?(String) || klass.is_a?(Symbol) ? Object.const_get(klass.to_s) : klass
      end
  end
end
