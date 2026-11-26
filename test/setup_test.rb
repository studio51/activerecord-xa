# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# How the gem is configured and loaded, as an application meets it.
class SetupTest < ActiveXATestCase
  def teardown
    ActiveXA.config.participants = []
    ActiveXA.config.decision_log_class = PrimaryRecord
  end

  def test_classes_can_be_configured_by_name
    ActiveXA.config.decision_log_class = "PrimaryRecord"
    ActiveXA.config.participants = %w[PrimaryRecord TrackerRecord]

    assert_equal PrimaryRecord.connection_pool, ActiveXA.decision_log.instance_variable_get(:@pool)
    assert_equal [ PrimaryRecord, TrackerRecord ], ActiveXA.config.resolved_participants
  end

  def test_recover_uses_the_configured_participants
    gtrid = new_gtrid
    ActiveXA.decision_log.record_commit!(gtrid, %w[primary tracker])
    ActiveXA.config.participants = %w[PrimaryRecord TrackerRecord]
    ActiveXA.config.recovery_grace_period = 0

    assert_equal [ gtrid ], ActiveXA.recover!.pruned
  ensure
    ActiveXA.config.recovery_grace_period = 60
  end

  def test_recover_without_participants_is_a_configuration_error
    error = assert_raises(ActiveXA::ConfigurationError) { ActiveXA.recover! }
    assert_match(/participants/, error.message)
  end

  def test_a_missing_decision_log_class_is_a_configuration_error
    ActiveXA.config.decision_log_class = nil

    assert_raises(ActiveXA::ConfigurationError) { ActiveXA.transaction(PrimaryRecord, TrackerRecord) { nil } }
  end

  def test_requiring_the_gem_does_not_load_active_record_base
    script = 'require "active_xa"; exit(ActiveRecord.autoload?(:Base) ? 0 : 1)'
    _out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)

    assert status.success?, "ActiveRecord::Base was loaded by require \"active_xa\" #{ err }"
  end
end
