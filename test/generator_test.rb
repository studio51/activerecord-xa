# frozen_string_literal: true

require "minitest/autorun"
require "rails/generators"
require "rails/generators/test_case"
require "active_record/xa"
require "generators/xa/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests ActiveRecord::XA::Generators::InstallGenerator
  destination File.expand_path("../tmp/generator", __dir__)
  setup :prepare_destination

  def test_is_found_under_the_name_the_docs_use
    assert_equal "xa:install", ActiveRecord::XA::Generators::InstallGenerator.namespace
    assert_equal ActiveRecord::XA::Generators::InstallGenerator, Rails::Generators.find_by_namespace("xa:install")
  end

  def test_writes_the_initializer
    run_generator

    assert_file "config/initializers/xa.rb" do |content|
      assert_match(/config\.decision_log_class = "ApplicationRecord"/, content)
      assert_match(/config\.participants = %w\[ApplicationRecord\]/, content)
    end
  end

  def test_writes_the_decision_log_migration
    run_generator

    assert_migration "db/migrate/create_xa_decisions.rb" do |content|
      assert_match(/class CreateXaDecisions < ActiveRecord::Migration\[\d+\.\d+\]/, content)
      assert_match(/execute ActiveRecord::XA::DecisionLog\.create_table_sql/, content)
    end
  end
end
