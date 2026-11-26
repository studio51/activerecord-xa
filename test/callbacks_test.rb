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

    assert_equal [:event, :order, :order_from_event], Events.log.grep(Symbol).sort
  end

  def test_before_commit_callbacks_that_keep_enrolling_each_other_terminate
    spawn = nil
    spawn = -> { HookedEvent.create!(on_before_commit: -> { HookedOrder.create!(on_before_commit: spawn) }) }

    Timeout.timeout(10) do
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) { HookedOrder.create!(on_before_commit: spawn) }
    end

    # As with nested Rails transactions: the record the event adds while the
    # primary is still running its callbacks gets no before_commit of its own.
    assert_equal [2, 1], counts
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

  def test_before_commit_failure_rolls_everything_back
    assert_raises(RuntimeError) do
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
        Order.create!(name: "order")
        HookedEvent.create!(on_before_commit: -> { raise "not today" })
      end
    end

    assert_equal [0, 0], counts
    assert_empty prepared_xids(PrimaryRecord)
  end
end
