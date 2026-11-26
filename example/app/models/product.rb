# frozen_string_literal: true

# Something to sell, in the shop database.
class Product < ApplicationRecord
  CRASH_TEST = "Crash test dummy" # name prefix of the products script/crash_mid_commit.rb sells

  has_many :orders, dependent: :destroy

  scope :for_sale, -> { where.not("name LIKE ?", "#{ CRASH_TEST }%") }
  scope :crash_tests, -> { where("name LIKE ?", "#{ CRASH_TEST }%") }
end
