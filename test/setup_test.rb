# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# How the gem is configured and loaded, as an application meets it.
class SetupTest < XATestCase
  def teardown
    ActiveRecord::XA.config.participants = []
    ActiveRecord::XA.config.decision_log_class = PrimaryRecord
  end

  def test_classes_can_be_configured_by_name
    ActiveRecord::XA.config.decision_log_class = "PrimaryRecord"
    ActiveRecord::XA.config.participants = %w[PrimaryRecord TrackerRecord]

    assert_equal PrimaryRecord.connection_pool, ActiveRecord::XA.decision_log.instance_variable_get(:@pool)
    assert_equal [ PrimaryRecord, TrackerRecord ], ActiveRecord::XA.config.resolved_participants
  end

  def test_recover_uses_the_configured_participants
    gtrid = new_gtrid
    ActiveRecord::XA.decision_log.record_commit!(gtrid, %w[primary tracker])
    ActiveRecord::XA.config.participants = %w[PrimaryRecord TrackerRecord]
    ActiveRecord::XA.config.recovery_grace_period = 0

    assert_equal [ gtrid ], ActiveRecord::XA.recover!.pruned
  ensure
    ActiveRecord::XA.config.recovery_grace_period = 60
  end

  def test_recover_without_participants_is_a_configuration_error
    error = assert_raises(ActiveRecord::XA::ConfigurationError) { ActiveRecord::XA.recover! }
    assert_match(/participants/, error.message)
  end

  def test_a_missing_decision_log_class_is_a_configuration_error
    ActiveRecord::XA.config.decision_log_class = nil

    assert_raises(ActiveRecord::XA::ConfigurationError) { ActiveRecord::XA.transaction(PrimaryRecord, TrackerRecord) { nil } }
  end

  def test_requiring_the_gem_does_not_load_active_record_base
    script = 'require "active_record/xa"; exit(ActiveRecord.autoload?(:Base) ? 0 : 1)'
    _out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)

    assert status.success?, "ActiveRecord::Base was loaded by require \"active_record/xa\" #{ err }"
  end
end
