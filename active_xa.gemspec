# frozen_string_literal: true

require_relative "lib/active_xa/version"

Gem::Specification.new do |s|
  s.name        = "active_xa"
  s.version     = ActiveXA::VERSION
  s.summary     = "Two-phase commit across MySQL databases for Active Record"
  s.description = "Atomic transactions across multiple MySQL databases in Rails, " \
                  "using MySQL XA, with a decision log and crash recovery."
  s.authors     = ["Vlad"]
  s.license     = "MIT"
  s.files       = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  s.required_ruby_version = ">= 3.2"

  s.add_dependency "activerecord", ">= 8.1", "< 8.2"
end
