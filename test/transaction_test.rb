# frozen_string_literal: true

require_relative "test_helper"

class TransactionTest < ActiveXATestCase
  def test_commits_on_both_databases
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      TrackerEvent.create!(name: "tracked")
      Order.create!(name: "order")
    end

    assert_equal [1, 1], counts
    assert_empty prepared_xids(PrimaryRecord)
    assert_empty ActiveXA.decision_log.entries, "decision row should be cleared after a clean commit"
  end

  def test_returns_block_value
    assert_equal :done, ActiveXA.transaction(PrimaryRecord, TrackerRecord) { Order.create!; :done }
  end

  def test_the_articles_failure_case_rolls_back_both
    # The article's scenario: tracker write fine, then the primary side fails.
    assert_raises(RuntimeError) do
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
        TrackerEvent.create!(name: "tracked")
        Order.create!(name: "order")
        raise "boom after both writes"
      end
    end

    assert_equal [0, 0], counts
    assert_includes Events.log, [:order_after_rollback]
  end

  def test_active_record_rollback_rolls_back_every_database_quietly
    result = ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "order")
      TrackerEvent.create!(name: "tracked")
      raise ActiveRecord::Rollback
    end

    assert_nil result
    assert_equal [0, 0], counts
    assert_includes Events.log, [:order_after_rollback]
    assert_empty prepared_xids(PrimaryRecord)
  end

  def test_active_record_rollback_when_only_the_outer_database_was_touched
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "order")
      raise ActiveRecord::Rollback
    end

    assert_equal [0, 0], counts
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) { Order.create!(name: "next"); TrackerEvent.create!(name: "next") }
    assert_equal [1, 1], counts
  end

  def test_prepare_failure_rolls_back_the_database_that_already_prepared
    FaultInjection.rules = { end_and_prepare!: /tracker/ }

    assert_raises(ActiveXA::PrepareFailed) do
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
        Order.create!(name: "order")
        TrackerEvent.create!(name: "tracked")
      end
    end

    assert_equal [0, 0], counts
    assert_empty prepared_xids(PrimaryRecord)
    assert_empty prepared_xids(TrackerRecord)
    assert_empty ActiveXA.decision_log.entries
  end

  def test_after_commit_runs_only_once_every_database_has_committed
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      TrackerEvent.create!(name: "tracked", check_order_visible: true)
      Order.create!(name: "order")
    end

    # With plain nested Rails transactions this would be 0: the tracker
    # commits (and fires after_commit) before the primary does.
    assert_includes Events.log, [:order_visible_in_tracker_after_commit, 1]
  end

  def test_before_commit_runs_once_and_before_prepare
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "order")
      TrackerEvent.create!(name: "tracked")
    end

    assert_equal 1, Events.log.count([:tracker_before_commit])
  end

  def test_single_database_touched_uses_one_phase_commit_and_no_log
    log = ActiveXA.decision_log
    def log.record_commit!(*) = raise("decision log should not be used")
    ActiveXA.stub(:decision_log, log) do
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) { Order.create!(name: "solo") }
    end

    assert_equal [1, 0], counts
  end

  def test_untouched_transaction_is_fine
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) { nil }
    assert_equal [0, 0], counts
  end

  def test_early_return_commits_like_rails_does
    early_return_helper
    assert_equal [1, 1], counts
  end

  def test_early_return_commits_even_while_another_exception_is_being_handled
    begin
      raise "unrelated"
    rescue RuntimeError
      early_return_helper
    end

    assert_equal [1, 1], counts
  end

  def test_throw_commits_like_rails_does
    catch(:done) do
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
        Order.create!(name: "order")
        TrackerEvent.create!(name: "tracked")
        throw :done
      end
    end

    assert_equal [1, 1], counts
  end

  def test_killing_the_thread_rolls_back_like_rails_does
    written = Queue.new
    thread = Thread.new do
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
        Order.create!(name: "order")
        TrackerEvent.create!(name: "tracked")
        written << true
        sleep
      end
    end
    written.pop
    thread.kill
    thread.join

    assert_equal [0, 0], counts
    assert_empty prepared_xids(PrimaryRecord)
  end

  def test_nested_requires_new_rollback_inside_xa
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "kept")
      Order.transaction(requires_new: true) do
        Order.create!(name: "discarded")
        raise ActiveRecord::Rollback
      end
      TrackerEvent.create!(name: "tracked")
    end

    assert_equal ["kept"], Order.pluck(:name)
    assert_equal 1, TrackerEvent.count
  end

  def test_nested_requires_new_rollback_before_the_first_write
    # Rails restarts the outer transaction instead of using a savepoint
    # here: XA ROLLBACK, then XA START again under the same XID.
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.transaction(requires_new: true) do
        Order.create!(name: "discarded")
        raise ActiveRecord::Rollback
      end
      Order.create!(name: "kept")
      TrackerEvent.create!(name: "tracked")
    end

    assert_equal ["kept"], Order.pluck(:name)
    assert_equal 1, TrackerEvent.count
  end

  def test_nested_non_joinable_transaction_uses_a_savepoint
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "outer")
      Order.transaction(joinable: false) { Order.create!(name: "inner") }
      TrackerEvent.create!(name: "tracked")
    end

    assert_equal %w[outer inner], Order.order(:id).pluck(:name)
    assert_equal 1, TrackerEvent.count
  end

  def test_a_branch_cannot_be_started_twice
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "order")
      TrackerEvent.create!(name: "tracked")
      branch = PrimaryRecord.lease_connection.active_xa_branch

      error = assert_raises(ActiveXA::UnsupportedOperation) { branch.start! }
      assert_match(/is active and cannot be started again/, error.message)
    end

    assert_equal [1, 1], counts
  end

  def test_refuses_to_join_an_already_open_transaction
    assert_raises(ActiveXA::TransactionAlreadyOpen) do
      Order.transaction do
        ActiveXA.transaction(PrimaryRecord, TrackerRecord) { Order.create! }
      end
    end
  end

  def test_needs_two_different_databases
    assert_raises(ArgumentError) { ActiveXA.transaction(PrimaryRecord, Order) { nil } }
  end

  def test_connections_are_usable_normally_afterwards
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) { Order.create!; TrackerEvent.create! }
    Order.transaction { Order.create! }
    TrackerEvent.create!
    assert_equal [2, 2], counts
  end

  def test_connections_go_back_to_the_pool_afterwards
    leased = in_new_thread do
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) { Order.create!; TrackerEvent.create! }
      leased_connections
    end

    assert_empty leased
  end

  def test_connections_go_back_to_the_pool_after_a_rollback
    leased = in_new_thread do
      assert_raises(RuntimeError) do
        ActiveXA.transaction(PrimaryRecord, TrackerRecord) { Order.create!; raise "boom" }
      end
      leased_connections
    end

    assert_empty leased
  end

  def test_a_connection_the_caller_already_holds_stays_with_the_caller
    kept = in_new_thread do
      held = PrimaryRecord.lease_connection
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) { Order.create!; TrackerEvent.create! }
      leased_connections == [held]
    ensure
      PrimaryRecord.connection_pool.release_connection
    end

    assert kept, "only the connection leased before the transaction should still be leased"
  end

  def test_refusing_an_open_transaction_releases_the_connections_already_taken
    leased = in_new_thread do
      TrackerRecord.transaction do
        assert_raises(ActiveXA::TransactionAlreadyOpen) do
          ActiveXA.transaction(PrimaryRecord, TrackerRecord) { Order.create! }
        end
      end
      leased_connections
    end

    assert_empty leased
  end

  private
    def early_return_helper
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
        Order.create!(name: "order")
        TrackerEvent.create!(name: "tracked")
        return
      end
    end
end
