class CreateLedgerEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :ledger_entries do |t|
      t.bigint :order_id
      t.integer :amount_cents
      t.string :note

      t.timestamps
    end
    add_index :ledger_entries, :order_id
  end
end
