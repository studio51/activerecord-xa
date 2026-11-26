# frozen_string_literal: true

require_relative "test_helper"

class XidTest < ActiveXATestCase
  def test_bqual_names_the_branch_after_its_position_and_database
    assert_equal "1-tracker", ActiveXA::Xid.bqual(1, "tracker")
  end

  def test_bqual_is_cut_to_64_bytes_not_64_characters
    bqual = ActiveXA::Xid.bqual(0, WIDE_NAME)

    assert_operator bqual.bytesize, :<=, 64
    assert_predicate bqual, :valid_encoding?
    assert bqual.start_with?("0-数据库")
  end

  def test_gtrid_carries_its_namespace_and_start_time
    gtrid = ActiveXA::Xid.generate_gtrid("0badc0de")

    assert_operator gtrid.bytesize, :<=, 64
    assert_equal "0badc0de", ActiveXA::Xid.namespace(gtrid)
    assert_in_delta Time.now.to_f, ActiveXA::Xid.created_at(gtrid).to_f, 1
  end

  def test_a_gtrid_from_elsewhere_has_no_namespace
    assert_nil ActiveXA::Xid.namespace("some-other-coordinator")
    assert_nil ActiveXA::Xid.created_at("some-other-coordinator")
    assert_nil ActiveXA::Xid.namespace("axa-\xFF".dup.force_encoding("UTF-8"))
  end

  def test_the_namespace_follows_the_decision_logs_database_unless_set
    primary = ActiveXA::DecisionLog.new(PrimaryRecord.connection_pool).namespace
    tracker = ActiveXA::DecisionLog.new(TrackerRecord.connection_pool).namespace

    assert_match(/\A\h{8}\z/, primary)
    refute_equal primary, tracker
    assert_equal ActiveXA::DecisionLog.new(PrimaryRecord.connection_pool, namespace: "billing").namespace,
                 ActiveXA::DecisionLog.new(TrackerRecord.connection_pool, namespace: "billing").namespace
  end

  def test_a_database_with_a_long_multibyte_name_can_take_part
    ActiveXA.transaction(PrimaryRecord, WideNameRecord) do
      Order.create!(name: "order")
      WideNameEvent.create!(name: "tracked")
    end

    assert_equal [1, 1], counts
    assert_empty prepared_xids(PrimaryRecord)
  end
end
