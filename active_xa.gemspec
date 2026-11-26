# frozen_string_literal: true

require_relative "lib/active_xa/version"

Gem::Specification.new do |spec|
  spec.name        = "active_xa"
  spec.version     = ActiveXA::VERSION
  spec.authors     = [ "Vlad Radulescu" ]
  spec.email       = [ "vlad@studio51.solutions" ]
  spec.homepage    = "https://github.com/studio51/activerecord-xa"
  spec.summary     = "Atomic transactions across multiple MySQL databases for Active Record."
  spec.description = <<~TEXT.freeze
    Nested transaction blocks on different databases look atomic but are not:
    the inner one commits when its block exits. ActiveXA runs them as one
    transaction with MySQL's XA two-phase commit, so every database commits or
    none does. A durable decision log and a recovery task finish whatever a
    crash leaves half done. Models are used exactly as normal inside the block.
  TEXT
  spec.license = "MIT"

  # Studio51 tracks the latest stable Ruby only.
  #
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["homepage_uri"]          = spec.homepage
  spec.metadata["source_code_uri"]       = spec.homepage
  spec.metadata["changelog_uri"]         = "#{ spec.homepage }/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]       = "#{ spec.homepage }/issues"
  spec.metadata["documentation_uri"]     = "#{ spec.homepage }/tree/main/docs"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*",
    "docs/**/*.md",
    "LICENSE",
    "COPYRIGHT",
    "README.md",
    "CHANGELOG.md",
  ]
  spec.require_paths = [ "lib" ]

  # ActiveXA hooks undocumented adapter internals (internal_execute, the
  # transaction stack), so each Rails minor version is tested before it is
  # allowed in.
  #
  spec.add_dependency "activerecord", ">= 8.1", "< 8.2"
end
