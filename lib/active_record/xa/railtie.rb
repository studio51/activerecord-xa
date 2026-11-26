# frozen_string_literal: true

module ActiveRecord::XA

  # Plugs ActiveRecord::XA into a Rails application: adds the xa:recover task.
  # The install generator is found by Rails on its own, under lib/generators.
  #
  class Railtie < Rails::Railtie
    rake_tasks do
      namespace :xa do
        desc "Resolve prepared XA branches left by a crash or a failed commit (uses ActiveRecord::XA.config.participants)"
        task recover: :environment do
          report = ActiveRecord::XA.recover!

          puts "committed: #{ report.committed.size }, rolled back: #{ report.rolled_back.size }, " \
               "skipped: #{ report.skipped.size }, pruned: #{ report.pruned.size }, errors: #{ report.errors.size }"
          report.errors.each { |subject, error| puts "  #{ subject }: #{ error.class }: #{ error.message }" }
        end
      end
    end
  end
end
