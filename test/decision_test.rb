# frozen_string_literal: true

require_relative "test_helper"

# What happens around the commit decision: the moment a transaction stops
# being this process's to roll back.
class DecisionTest < ActiveXATestCase
  def test_recovery_that_gets_in_before_the_decision_makes_the_coordinator_roll_back
    error = nil
    gtrid = long_running_transaction do
      with_decision_log(before: ->(_) { recover(grace: 60) }) do
        error = assert_raises(ActiveXA::DecisionLogFailed) { write_to_both }
      end
    end

    assert_match(/recovery rolled .* back/, error.message)
    assert_equal [0, 0], counts
    assert_empty prepared_xids(PrimaryRecord)
    assert_equal :abort, ActiveXA.decision_log.outcome(gtrid)
    assert_includes Events.log, [:order_after_rollback]
  end

  def test_recovery_that_arrives_after_the_decision_commits_what_the_coordinator_decided
    reported = []
    ActiveXA.config.on_incomplete_commit = ->(gtrid, failures) { reported << gtrid }

    gtrid = long_running_transaction do
      with_decision_log(after: ->(_) { recover(grace: 60) }) { write_to_both }
    end

    assert_equal [1, 1], counts
    assert_empty prepared_xids(PrimaryRecord)
    assert_equal [gtrid], reported, "the coordinator's own XA COMMITs found the branches already committed"
  end

  def test_an_exception_during_the_commit_phase_cannot_undo_a_decided_transaction
    FaultInjection.rules = { commit!: [/tracker/, -> { raise Stop }] }
    order = nil

    assert_raises(Stop) do
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
        order = Order.create!(name: "order")
        TrackerEvent.create!(name: "tracked")
      end
    end

    assert_equal [1, 0], counts
    assert_equal 1, prepared_xids(TrackerRecord).size, "the tracker branch must still be prepared, not rolled back"
    assert_predicate order, :persisted?
    assert_includes Events.log, [:order_after_commit, order.id]
    refute_includes Events.log, [:order_after_rollback]

    FaultInjection.rules = {}
    assert_equal 1, recover(grace: 0).committed.size
    assert_equal [1, 1], counts
  end

  def test_killing_the_thread_during_the_commit_phase_cannot_undo_a_decided_transaction
    FaultInjection.rules = { commit!: [/tracker/, -> { Thread.current.kill }] }

    Thread.new { write_to_both }.join

    assert_equal [1, 0], counts
    FaultInjection.rules = {}
    assert_equal 1, recover(grace: 0).committed.size
    assert_equal [1, 1], counts
  end

  def test_an_exception_just_after_the_decision_is_logged_leaves_the_branches_to_recovery
    with_decision_log(after: ->(_) { raise Stop }) do
      assert_raises(Stop) { write_to_both }
    end

    assert_equal 2, prepared_xids(PrimaryRecord).size, "nothing may be rolled back once the decision is in the log"
    assert_no_commit_or_rollback_callbacks

    assert_equal 2, recover(grace: 0).committed.size
    assert_equal [1, 1], counts
  end

  def test_an_exception_just_before_the_decision_is_logged_leaves_the_branches_to_recovery
    with_decision_log(before: ->(_) { raise Stop }) do
      assert_raises(Stop) { write_to_both }
    end

    assert_equal 2, prepared_xids(PrimaryRecord).size
    assert_equal 2, recover(grace: 0).rolled_back.size
    assert_equal [0, 0], counts
  end

  def test_a_decision_that_was_logged_despite_the_error_still_commits
    with_decision_log(after: ->(_) { raise ActiveRecord::ConnectionFailed, "lost the acknowledgement" }) do
      write_to_both
    end

    assert_equal [1, 1], counts
    assert_empty prepared_xids(PrimaryRecord)
    assert_empty ActiveXA.decision_log.entries
  end

  def test_a_decision_that_could_not_be_logged_rolls_everything_back_for_good
    gtrid = nil
    with_decision_log(before: ->(g) { gtrid = g; raise ActiveRecord::ConnectionFailed, "log is down" }) do
      error = assert_raises(ActiveXA::DecisionLogFailed) { write_to_both }
      assert_match(/log is down/, error.message)
    end

    assert_equal [0, 0], counts
    assert_empty prepared_xids(PrimaryRecord)
    assert_equal :abort, ActiveXA.decision_log.outcome(gtrid), "so that a commit row arriving late is refused"
    assert_includes Events.log, [:order_after_rollback]
  end

  def test_a_decision_that_was_never_sent_rolls_back_without_consulting_the_log
    with_decision_log(before: ->(_) { raise ActiveRecord::ConnectionTimeoutError, "no connection to the log" }) do |log|
      def log.settle!(*) = raise("the log should not be asked: nothing was sent")

      error = assert_raises(ActiveXA::DecisionLogFailed) { write_to_both }
      assert_match(/no connection to the log/, error.message)
    end

    assert_equal [0, 0], counts
    assert_empty prepared_xids(PrimaryRecord)
    assert_includes Events.log, [:order_after_rollback]
  end

  def test_nothing_is_rolled_back_while_the_log_cannot_say_what_was_decided
    with_decision_log(before: ->(_) { raise ActiveRecord::ConnectionFailed, "log is down" }) do |log|
      def log.settle!(*) = raise(ActiveRecord::ConnectionFailed, "still down")

      error = assert_raises(ActiveXA::OutcomeUnknown) { write_to_both }
      assert_match(/log is down.*still down/, error.message)
    end

    assert_equal 2, prepared_xids(PrimaryRecord).size
    assert_no_commit_or_rollback_callbacks

    assert_equal 2, recover(grace: 0).rolled_back.size
    assert_equal [0, 0], counts
  end

  def test_a_failing_on_incomplete_commit_callback_does_not_fail_the_transaction
    ActiveXA.config.on_incomplete_commit = ->(*) { raise "pager is down" }
    FaultInjection.rules = { commit!: /tracker/ }
    order = nil

    ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
      order = Order.create!(name: "order")
      TrackerEvent.create!(name: "tracked")
    end

    assert_predicate order, :persisted?
    assert_includes Events.log, [:order_after_commit, order.id]
  end

  private
    # The outcome is not known to this process, so neither kind may run.
    def assert_no_commit_or_rollback_callbacks
      assert_empty Events.log.select { |event, *| %i[order_after_commit order_after_rollback].include?(event) }
    end

    def write_to_both
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
        Order.create!(name: "order")
        TrackerEvent.create!(name: "tracked")
      end
    end
end
