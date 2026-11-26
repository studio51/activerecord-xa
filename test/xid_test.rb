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

  def test_a_database_with_a_long_multibyte_name_can_take_part
    ActiveXA.transaction(PrimaryRecord, WideNameRecord) do
      Order.create!(name: "order")
      WideNameEvent.create!(name: "tracked")
    end

    assert_equal [1, 1], counts
    assert_empty prepared_xids(PrimaryRecord)
  end
end
