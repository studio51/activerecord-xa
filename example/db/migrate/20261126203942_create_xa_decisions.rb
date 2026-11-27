# frozen_string_literal: true

class CreateXaDecisions < ActiveRecord::Migration[8.1]
  def up
    execute ActiveRecord::XA::DecisionLog.create_table_sql
  end

  def down
    drop_table ActiveRecord::XA::DecisionLog::TABLE
  end
end
