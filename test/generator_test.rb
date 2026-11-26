# frozen_string_literal: true

require "minitest/autorun"
require "rails/generators"
require "rails/generators/test_case"
require "active_xa"
require "generators/active_xa/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests ActiveXA::Generators::InstallGenerator
  destination File.expand_path("../tmp/generator", __dir__)
  setup :prepare_destination

  def test_writes_the_initializer
    run_generator

    assert_file "config/initializers/active_xa.rb" do |content|
      assert_match(/config\.decision_log_class = "ApplicationRecord"/, content)
      assert_match(/config\.participants = %w\[ApplicationRecord\]/, content)
    end
  end

  def test_writes_the_decision_log_migration
    run_generator

    assert_migration "db/migrate/create_active_xa_decisions.rb" do |content|
      assert_match(/class CreateActiveXaDecisions < ActiveRecord::Migration\[\d+\.\d+\]/, content)
      assert_match(/execute ActiveXA::DecisionLog\.create_table_sql/, content)
    end
  end
end
