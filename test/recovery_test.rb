# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class RecoveryTest < ActiveXATestCase
  def test_commit_failure_leaves_branch_in_doubt_and_recovery_commits_it
    reported = nil
    ActiveXA.config.on_incomplete_commit = ->(gtrid, failures) { reported = [gtrid, failures.size] }
    FaultInjection.rules = { commit!: /tracker/ }

    # Not raised: the decision is logged, so the transaction is committed.
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "order")
      TrackerEvent.create!(name: "tracked")
    end

    assert_equal 1, reported.last
    assert_equal 1, Order.count
    assert_equal 1, prepared_xids(TrackerRecord).size, "only the tracker branch should be waiting in PREPARED"

    FaultInjection.rules = {}
    report = ActiveXA::Recovery.new([PrimaryRecord, TrackerRecord], log: ActiveXA.decision_log, grace: 0).run

    assert_equal 1, report.committed.size
    assert_equal [1, 1], counts
    assert_empty ActiveXA.decision_log.entries
  end

  def test_crash_after_decision_is_committed_by_recovery
    gtrid = simulate_crash(log_decision: true)
    assert_equal [0, 0], counts

    report = recover(grace: 0)
    assert_equal [gtrid, gtrid], report.committed.map(&:gtrid)
    assert_equal [1, 1], counts
  end

  def test_crash_before_decision_is_rolled_back_by_recovery
    simulate_crash(log_decision: false)

    report = recover(grace: 0)
    assert_equal 2, report.rolled_back.size
    assert_equal [0, 0], counts
    assert_empty prepared_xids(PrimaryRecord)
  end

  def test_recovery_leaves_young_transactions_alone
    simulate_crash(log_decision: false)

    report = recover(grace: 3600)
    assert_equal 2, report.skipped.size
    # Both branches still PREPARED (XA RECOVER is server-wide in this setup).
    assert_equal 2, prepared_xids(PrimaryRecord).size
  end

  def test_recovery_prunes_decisions_with_nothing_left_to_do
    ActiveXA.decision_log.record_commit!(ActiveXA::Xid.generate_gtrid, [])
    report = recover(grace: 0)
    assert_equal 1, report.pruned.size
    assert_empty ActiveXA.decision_log.entries
  end

  def test_recovery_resolves_branches_with_multibyte_qualifiers
    gtrid = simulate_crash(log_decision: true, bqual_name: WIDE_NAME)

    report = recover(grace: 0)
    assert_empty report.errors
    assert_equal [gtrid, gtrid], report.committed.map(&:gtrid)
    assert_equal [1, 1], counts
  end

  private
    def recover(grace:)
      ActiveXA::Recovery.new([PrimaryRecord, TrackerRecord], log: ActiveXA.decision_log, grace: grace).run
    end

    # Prepare a branch on each database through raw connections, optionally
    # log the decision, then drop the connections as a dying process would.
    def simulate_crash(log_decision:, bqual_name: "crash")
      gtrid = ActiveXA::Xid.generate_gtrid
      branches = [[PrimaryRecord, "orders"], [TrackerRecord, "tracker_events"]].map.with_index do |(klass, table), i|
        conn = klass.connection_pool.checkout
        xid = ActiveXA::Xid.new(gtrid, ActiveXA::Xid.bqual(i, bqual_name))
        conn.execute("XA START #{xid.to_sql(conn)}")
        conn.execute("INSERT INTO #{table} (name) VALUES ('crashed')")
        conn.execute("XA END #{xid.to_sql(conn)}")
        conn.execute("XA PREPARE #{xid.to_sql(conn)}")
        [klass, conn]
      end

      if log_decision
        ActiveXA.decision_log.record_commit!(gtrid, [])
      end

      branches.each do |klass, conn|
        conn.disconnect!
        klass.connection_pool.remove(conn)
      end
      gtrid
    end
end
