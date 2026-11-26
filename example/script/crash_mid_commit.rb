# frozen_string_literal: true

# Sells a fresh crash-test product and kills this process in the middle of the
# commit, the way a deploy, an OOM kill or a power cut would.
#
#   bin/rails runner script/crash_mid_commit.rb after_decision
#   bin/rails runner script/crash_mid_commit.rb before_decision
#
# Both databases are left with a PREPARED branch holding its locks.
# After the decision, recovery commits them; before it, recovery rolls them back.
#
stage = ARGV.fetch(0) { abort "usage: crash_mid_commit.rb after_decision|before_decision" }
die = -> { Process.kill(:KILL, Process.pid) }

ActiveXA::DecisionLog.prepend(Module.new do
  define_method(:record_commit!) do |*args|
    die.call if stage == "before_decision"
    super(*args)
    die.call
  end
end)

# A product of its own, so the locks this crash leaves behind block nothing else, not even the next crash.
product = Product.create!(name: "#{ Product::CRASH_TEST } #{ SecureRandom.hex(2) }", stock: 1, price_cents: 100)

Checkout.new(product).call
