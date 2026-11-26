# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module ActiveXA
  module Generators

    # Sets ActiveXA up in a Rails application: an initializer and the decision log migration.
    #
    #   bin/rails generate active_xa:install --database primary
    #
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      # Rails would derive "active_x_a:install" from the class name.
      #
      namespace "active_xa:install"

      source_root File.expand_path("templates", __dir__)

      class_option :database, type: :string, aliases: %i[--db],
                              desc: "The database the decision log lives in; its migrations path gets the migration"

      # Writes config/initializers/active_xa.rb.
      #
      # @return [void]
      def create_initializer
        template "initializer.rb.tt", "config/initializers/active_xa.rb"
      end

      # Writes the migration that creates the decision log table.
      #
      # @return [void]
      def create_migration_file
        migration_template "migration.rb.tt", File.join(db_migrate_path, "create_active_xa_decisions.rb")
      end
    end
  end
end
