# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Everything below is for working on ActiveRecord::XA, not for using it.
#
group :development, :test do
  gem "rake"
  gem "minitest", "~> 6.1"
  gem "minitest-mock" # Minitest 6 moved minitest/mock (stub) out into its own gem
  gem "mysql2", "~> 0.5"
  gem "railties", "~> 8.1" # for the install generator and its test

  gem "rubocop", ">= 1.80", require: false
  gem "rubocop-performance", require: false
  gem "rubocop-rails-omakase", require: false

  # Studio51 house RuboCop cops (doc-block shape + method breathing room).
  #
  gem "rubocop-studio51", github: "studio51/standards",
                          glob: "rubocop-studio51/*.gemspec",
                          require: false,
                          ref: "b9caa479d6326790b8bd6719e2b3da171d6ddaac"
end
