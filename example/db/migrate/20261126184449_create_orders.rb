class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :product, null: false, foreign_key: true
      t.integer :quantity
      t.integer :total_cents

      t.timestamps
    end
  end
end
