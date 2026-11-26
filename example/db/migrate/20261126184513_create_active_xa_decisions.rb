# frozen_string_literal: true

class CreateActiveXaDecisions < ActiveRecord::Migration[8.1]
  def up
    execute ActiveXA::DecisionLog.create_table_sql
  end

  def down
    drop_table ActiveXA::DecisionLog::TABLE
  end
end
