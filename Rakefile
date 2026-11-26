# frozen_string_literal: true

require "bundler/setup"
require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "test" << "lib"
  task.pattern = "test/**/*_test.rb"
  task.warning = false
end

task default: :test

desc "Measure the cost of a transaction with and without ActiveRecord::XA (needs the test databases)"
task :bench do
  ruby "benchmark/transactions.rb"
end
