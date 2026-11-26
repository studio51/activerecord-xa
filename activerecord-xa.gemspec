# frozen_string_literal: true

require_relative "lib/active_record/xa/version"

Gem::Specification.new do |spec|
  spec.name        = "activerecord-xa"
  spec.version     = ActiveRecord::XA::VERSION
  spec.authors     = [ "Vlad Radulescu" ]
  spec.email       = [ "vlad@studio51.solutions" ]
  spec.homepage    = "https://github.com/studio51/activerecord-xa"
  spec.summary     = "Atomic transactions across multiple MySQL databases for Active Record."
  spec.description = <<~TEXT.freeze
    Nested transaction blocks on different databases look atomic but are not:
    the inner one commits when its block exits. ActiveRecord::XA runs them as one
    transaction with MySQL's XA two-phase commit, so every database commits or
    none does. A durable decision log and a recovery task finish whatever a
    crash leaves half done. Models are used exactly as normal inside the block.
  TEXT
  spec.license = "MIT"

  # Studio51 tracks the latest stable Ruby only.
  #
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["source_code_uri"]       = spec.homepage
  spec.metadata["changelog_uri"]         = "#{ spec.homepage }/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]       = "#{ spec.homepage }/issues"
  spec.metadata["documentation_uri"]     = "#{ spec.homepage }/tree/main/docs"
  spec.metadata["rubygems_mfa_required"] = "true"

  # An allowlist, so the example app, tests, benchmark and CI config stay in
  # the repository but out of the gem.
  #
  spec.files = Dir[
    "lib/**/*",
    "docs/**/*.md",
    "LICENSE",
    "COPYRIGHT",
    "README.md",
    "CHANGELOG.md",
  ]
  spec.require_paths = [ "lib" ]

  # ActiveRecord::XA hooks undocumented adapter internals (internal_execute, the
  # transaction stack), so each Rails minor version is tested before it is
  # allowed in.
  #
  spec.add_dependency "activerecord", ">= 8.1", "< 8.2"
end
