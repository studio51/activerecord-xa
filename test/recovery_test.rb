# frozen_string_literal: true

require_relative "test_helper"

class RecoveryTest < XATestCase
  def test_commit_failure_leaves_branch_in_doubt_and_recovery_commits_it
    reported = nil
    ActiveRecord::XA.config.on_incomplete_commit = ->(gtrid, failures) { reported = [ gtrid, failures.size ] }
    FaultInjection.rules = { commit!: /tracker/ }

    # Not raised: the decision is logged, so the transaction is committed.
    ActiveRecord::XA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "order")
      TrackerEvent.create!(name: "tracked")
    end

    assert_equal 1, reported.last
    assert_equal 1, Order.count
    assert_equal 1, prepared_xids(TrackerRecord).size, "only the tracker branch should be waiting in PREPARED"

    FaultInjection.rules = {}
    report = recover(grace: 0)

    assert_equal 1, report.committed.size
    assert_equal [ 1, 1 ], counts
    assert_empty ActiveRecord::XA.decision_log.entries
  end

  def test_crash_after_decision_is_committed_by_recovery
    gtrid = simulate_crash(log_decision: true)
    assert_equal [ 0, 0 ], counts

    report = recover(grace: 0)
    assert_equal [ gtrid, gtrid ], report.committed.map(&:gtrid)
    assert_equal [ 1, 1 ], counts
  end

  def test_crash_before_decision_is_rolled_back_by_recovery
    simulate_crash(log_decision: false)

    report = recover(grace: 0)
    assert_equal 2, report.rolled_back.size
    assert_equal [ 0, 0 ], counts
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
    ActiveRecord::XA.decision_log.record_commit!(new_gtrid, [])
    report = recover(grace: 0)
    assert_equal 1, report.pruned.size
    assert_empty ActiveRecord::XA.decision_log.entries
  end

  def test_recovery_resolves_branches_with_multibyte_qualifiers
    gtrid = simulate_crash(log_decision: true, bqual_name: WIDE_NAME)

    report = recover(grace: 0)
    assert_empty report.errors
    assert_equal [ gtrid, gtrid ], report.committed.map(&:gtrid)
    assert_equal [ 1, 1 ], counts
  end

  def test_recovery_logs_the_abort_before_rolling_back_and_keeps_the_marker
    gtrid = simulate_crash(log_decision: false)

    report = recover(grace: 0, abort_retention: 3600)
    assert_equal 2, report.rolled_back.size
    assert_equal :abort, ActiveRecord::XA.decision_log.outcome(gtrid)
    assert_raises(ActiveRecord::RecordNotUnique, "a coordinator must not be able to log a commit now") do
      ActiveRecord::XA.decision_log.record_commit!(gtrid, [])
    end

    report = recover(grace: 0, abort_retention: 0)
    assert_equal [ gtrid ], report.pruned
    assert_empty ActiveRecord::XA.decision_log.entries
  end

  def test_every_branch_of_a_transaction_gets_the_same_outcome
    gtrid = simulate_crash(log_decision: false)
    log = ActiveRecord::XA.decision_log
    late_commit = nil
    # The coordinator turns out to be alive: it tries to log its commit as
    # soon as recovery has dealt with the first branch.
    log.singleton_class.prepend(Module.new do
      define_method(:settle!) do |settled_gtrid|
        super(settled_gtrid).tap do
          late_commit = begin
            record_commit!(settled_gtrid, [])
            :logged
          rescue ActiveRecord::RecordNotUnique
            :refused
          end
        end
      end
    end)

    report = ActiveRecord::XA::Recovery.new([ PrimaryRecord, TrackerRecord ], log:, grace: 0).run

    assert_equal :refused, late_commit
    assert_equal [ gtrid, gtrid ], report.rolled_back.map(&:gtrid)
    assert_equal [ 0, 0 ], counts
  end

  def test_a_commit_decision_is_pruned_by_its_own_age_not_the_transactions
    gtrid = long_running_transaction { ActiveRecord::XA.decision_log.record_commit!(new_gtrid, []) }

    report = recover(grace: 3600)
    assert_empty report.pruned, "the decision was logged a moment ago, however long ago the transaction began"
    assert_equal [ gtrid ], ActiveRecord::XA.decision_log.entries
  end

  def test_recovery_leaves_another_installations_branches_alone
    # Another application, or another environment of this one, using the
    # same server with a decision log of its own.
    simulate_crash(log_decision: false, gtrid: new_gtrid("0badc0de"))

    report = recover(grace: 0)

    assert_empty report.rolled_back + report.committed + report.skipped
    assert_empty ActiveRecord::XA.decision_log.entries
    assert_equal 2, prepared_xids(PrimaryRecord).size, "their branches are theirs to decide"
  end

  def test_recovery_ignores_xids_it_cannot_read
    simulate_crash(log_decision: false, gtrid: "not-an-activexa-gtrid")

    assert_empty recover(grace: 0).rolled_back
    assert_equal 2, prepared_xids(PrimaryRecord).size
  end

  def test_a_decision_is_only_pruned_by_a_run_that_covers_all_its_databases
    gtrid = new_gtrid
    ActiveRecord::XA.decision_log.record_commit!(gtrid, %w[primary tracker])

    partial = ActiveRecord::XA::Recovery.new([ PrimaryRecord ], log: ActiveRecord::XA.decision_log, grace: 0).run
    assert_empty partial.pruned, "a branch may be waiting on the database this run was not given"

    assert_equal [ gtrid ], recover(grace: 0).pruned
  end

  def test_a_database_that_cannot_be_reached_does_not_hold_up_the_others
    gtrid = simulate_crash(log_decision: true)

    report = ActiveRecord::XA::Recovery.new([ UnreachableRecord, PrimaryRecord, TrackerRecord ],
                                    log: ActiveRecord::XA.decision_log, grace: 0).run

    assert_equal [ gtrid, gtrid ], report.committed.map(&:gtrid)
    assert_equal [ 1, 1 ], counts
    assert_equal [ "unreachable" ], report.errors.map(&:first)
    assert_empty report.pruned, "the database that was not asked may hold a branch of any decision"
    assert_equal [ gtrid ], ActiveRecord::XA.decision_log.entries
  end

  private
    # Prepare a branch on each database through raw connections, optionally
    # log the decision, then drop the connections as a dying process would.
    def simulate_crash(log_decision:, bqual_name: "crash", gtrid: new_gtrid)
      branches = [ [ PrimaryRecord, "orders" ], [ TrackerRecord, "tracker_events" ] ].map.with_index do |(klass, table), i|
        conn = klass.connection_pool.checkout
        xid = ActiveRecord::XA::Xid.new(gtrid, ActiveRecord::XA::Xid.bqual(i, bqual_name))
        conn.execute("XA START #{ xid.to_sql(conn) }")
        conn.execute("INSERT INTO #{ table } (name) VALUES ('crashed')")
        conn.execute("XA END #{ xid.to_sql(conn) }")
        conn.execute("XA PREPARE #{ xid.to_sql(conn) }")
        [ klass, conn ]
      end

      if log_decision
        ActiveRecord::XA.decision_log.record_commit!(gtrid, %w[primary tracker])
      end

      branches.each do |klass, conn|
        conn.disconnect!
        klass.connection_pool.remove(conn)
      end
      gtrid
    end
end
