# frozen_string_literal: true

require_relative "test_helper"

# MySQL undoes the whole branch of a deadlock victim and marks it
# rollback-only: XA END and XA PREPARE fail, and only XA ROLLBACK closes it.
class DeadlockTest < ActiveXATestCase
  def test_the_victim_of_a_deadlock_sees_the_deadlock_and_everything_rolls_back
    assert_raises(ActiveRecord::Deadlocked) do
      with_deadlock_on_primary { |deadlocking_statement| deadlocking_statement.call }
    end

    assert_equal %w[a b], Order.order(:id).pluck(:name)
    assert_equal 0, TrackerEvent.count
    assert_includes Events.log, [ :order_after_rollback ]
    assert_empty prepared_xids(PrimaryRecord)
    assert_connections_still_work
  end

  def test_a_deadlock_the_block_swallows_still_aborts_the_whole_transaction
    assert_raises(ActiveXA::PrepareFailed) do
      with_deadlock_on_primary do |deadlocking_statement|
        deadlocking_statement.call
      rescue ActiveRecord::Deadlocked
        # Carrying on regardless: with plain transactions MySQL would now
        # commit whatever the block does next, without what came before.
      end
    end

    assert_equal %w[a b], Order.order(:id).pluck(:name)
    assert_equal 0, TrackerEvent.count
    assert_empty prepared_xids(PrimaryRecord)
    assert_connections_still_work
  end

  private
    # Runs an ActiveXA transaction whose primary branch becomes the victim
    # of a deadlock with another session. Yields the statement that will
    # deadlock, for the test to run inside the block.
    #
    # Each side holds one row and then asks for the other's. Whichever
    # starts waiting first, the second request closes the cycle, so there is
    # nothing to synchronise on.
    def with_deadlock_on_primary
      a = Order.create!(name: "a")
      b = Order.create!(name: "b")
      Events.clear
      pool = PrimaryRecord.connection_pool
      rival = pool.checkout
      waiting = nil

      rival.execute("BEGIN")
      rival.execute("UPDATE orders SET name = 'rival' WHERE id = #{ b.id }")
      # InnoDB sacrifices the transaction that has done less work. Make that ours.
      20.times { |i| rival.execute("INSERT INTO orders (name) VALUES ('padding #{ i }')") }

      ActiveXA.transaction(PrimaryRecord, TrackerRecord) do
        TrackerEvent.create!(name: "tracked")
        a.update!(name: "ours")
        waiting = Thread.new { rival.execute("UPDATE orders SET name = 'rival' WHERE id = #{ a.id }") }
        waiting.report_on_exception = false
        yield -> { Order.where(id: b.id).update_all(name: "ours") }
      end
    ensure
      begin
        waiting&.join
      rescue ActiveRecord::ActiveRecordError
        nil # the assertions in the test say what went wrong
      ensure
        rival.execute("ROLLBACK")
        pool.checkin(rival)
      end
    end

    def assert_connections_still_work
      Order.transaction { Order.create!(name: "plain") }
      ActiveXA.transaction(PrimaryRecord, TrackerRecord) { Order.create!(name: "xa"); TrackerEvent.create!(name: "xa") }

      assert_equal %w[plain xa], Order.order(:id).last(2).map(&:name)
      assert_equal [ "xa" ], TrackerEvent.pluck(:name)
    end
end
