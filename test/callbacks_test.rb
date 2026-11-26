# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class CallbacksTest < ActiveXATestCase
  def test_before_commit_runs_for_a_record_enrolled_by_the_other_databases_before_commit
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "order")
      HookedEvent.create!(on_before_commit: -> {
        HookedOrder.create!(name: "late", on_before_commit: -> { Events.log << :late_order_before_commit })
      })
    end

    assert_equal 1, Events.log.count(:late_order_before_commit)
    assert_equal %w[order late], Order.order(:id).pluck(:name)
  end

  def test_before_commit_runs_for_a_record_enrolled_in_a_database_that_already_had_its_turn
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      TrackerEvent.create!(name: "tracked")
      HookedOrder.create!(on_before_commit: -> {
        HookedEvent.create!(name: "late", on_before_commit: -> { Events.log << :late_event_before_commit })
      })
    end

    assert_equal 1, Events.log.count(:late_event_before_commit)
    assert_equal %w[tracked late], TrackerEvent.order(:id).pluck(:name)
  end

  def test_each_before_commit_runs_once_however_the_databases_interleave
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      HookedOrder.create!(on_before_commit: -> { Events.log << :order })
      HookedEvent.create!(on_before_commit: -> {
        Events.log << :event
        HookedOrder.create!(on_before_commit: -> { Events.log << :order_from_event })
      })
    end

    assert_equal [ :event, :order, :order_from_event ], Events.log.grep(Symbol).sort
  end

  def test_before_commit_callbacks_that_keep_enrolling_each_other_terminate
    spawn = nil
    spawn = -> { HookedEvent.create!(on_before_commit: -> { HookedOrder.create!(on_before_commit: spawn) }) }

    Timeout.timeout(10) do
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) { HookedOrder.create!(on_before_commit: spawn) }
    end

    # As with nested Rails transactions: the record the event adds while the
    # primary is still running its callbacks gets no before_commit of its own.
    assert_equal [ 2, 1 ], counts
  end

  def test_before_commit_callbacks_registered_on_the_transaction_run_once
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "order")
      TrackerEvent.create!(name: "tracked")
      PrimaryRecord.with_connection do |connection|
        connection.current_transaction.before_commit { Events.log << :transaction_before_commit }
      end
    end

    assert_equal 1, Events.log.count(:transaction_before_commit)
  end

  def test_after_commit_can_write_to_its_own_database
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "order")
      HookedEvent.create!(name: "tracked", on_after_commit: -> { TrackerEvent.create!(name: "from after_commit") })
    end

    assert_equal [ "tracked", "from after_commit" ], TrackerEvent.order(:id).pluck(:name)
    assert_empty prepared_xids(TrackerRecord)
  end

  def test_after_commit_gets_real_transactions_on_the_other_database
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "order")
      HookedEvent.create!(on_after_commit: -> {
        Order.transaction(requires_new: true) { Order.create!(name: "kept") }
        Order.transaction { Order.create!(name: "undone"); raise ActiveRecord::Rollback }
      })
    end

    assert_equal %w[order kept], Order.order(:id).pluck(:name)
  end

  def test_after_commit_can_start_another_xa_transaction
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "first")
      HookedEvent.create!(name: "first", on_after_commit: -> {
        ActiveXA.transaction(PrimaryRecord, TrackerRecord) { Order.create!(name: "second"); TrackerEvent.create!(name: "second") }
      })
    end

    assert_equal [ 2, 2 ], counts
  end

  def test_after_all_transactions_commit_runs_once_and_can_write
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      Order.create!(name: "order")
      TrackerEvent.create!(name: "tracked")
      ActiveRecord.after_all_transactions_commit do
        Events.log << [ :all_committed, counts ]
        Order.create!(name: "afterwards")
      end
    end

    assert_equal [ [ :all_committed, [ 1, 1 ] ] ], Events.log.select { |e| e.first == :all_committed }
    assert_equal 2, Order.count
  end

  def test_a_failing_after_commit_does_not_make_the_other_database_look_rolled_back
    order = nil
    error = assert_raises(RuntimeError) do
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
        order = Order.create!(name: "order")
        HookedEvent.create!(on_after_commit: -> { raise "after_commit failed" })
      end
    end

    assert_equal "after_commit failed", error.message
    assert_equal [ 1, 1 ], counts
    assert_predicate order, :persisted?, "the order is committed, so it must not be reset to a new record"
    assert_includes Events.log, [ :order_after_commit, order.id ]
    refute_includes Events.log, [ :order_after_rollback ]
  end

  def test_after_rollback_can_write_and_the_original_error_survives
    error = assert_raises(RuntimeError) do
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
        Order.create!(name: "order")
        HookedEvent.create!(on_after_rollback: -> { TrackerEvent.create!(name: "from after_rollback") })
        raise "boom"
      end
    end

    assert_equal "boom", error.message
    assert_equal 0, Order.count
    assert_equal [ "from after_rollback" ], TrackerEvent.pluck(:name)
  end

  def test_active_record_rollback_from_a_before_commit_callback_rolls_back_quietly
    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      HookedOrder.create!(name: "order", on_before_commit: -> { raise ActiveRecord::Rollback })
      TrackerEvent.create!(name: "tracked")
    end

    assert_equal [ 0, 0 ], counts
    assert_empty prepared_xids(PrimaryRecord)
  end

  def test_before_commit_failure_rolls_everything_back
    assert_raises(RuntimeError) do
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
        Order.create!(name: "order")
        HookedEvent.create!(on_before_commit: -> { raise "not today" })
      end
    end

    assert_equal [ 0, 0 ], counts
    assert_empty prepared_xids(PrimaryRecord)
  end
end
