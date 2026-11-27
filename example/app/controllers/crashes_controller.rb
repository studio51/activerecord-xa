# frozen_string_literal: true

# Runs script/crash_mid_commit.rb in a separate process that kills itself mid-commit.
class CrashesController < ApplicationController
  STAGES = %w[after_decision before_decision].freeze

  def create
    stage = STAGES.find { |s| s == params[:stage] } or raise ActionController::BadRequest
    pid = Process.spawn(Rails.root.join("bin/rails").to_s, "runner", "script/crash_mid_commit.rb", stage, chdir: Rails.root.to_s)
    Process.wait(pid)

    redirect_to root_path, alert: "A checkout process was killed #{ stage.tr("_", " ") }. " \
                                  "Its branches are prepared and holding their locks; run recovery once they are #{ ActiveRecord::XA.config.recovery_grace_period } seconds old."
  end
end
