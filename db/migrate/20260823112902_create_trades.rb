class CreateTrades < ActiveRecord::Migration[8.1]
  def change
    create_table :trades do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :instrument, null: false, foreign_key: true
      t.references :institution, null: true, foreign_key: true
      t.string :side, null: false
      t.date :traded_on, null: false
      t.decimal :quantity, precision: 20, scale: 8, null: false
      t.integer :unit_price_cents, null: false
      t.integer :fees_cents, null: false, default: 0
      t.string :currency, limit: 3, null: false
      t.text :notes

      t.timestamps
    end

    add_index :trades, %i[user_id traded_on]
    add_index :trades, %i[user_id instrument_id traded_on]
    add_check_constraint :trades, "side IN ('buy', 'sell')", name: "trades_side_check"
    add_check_constraint :trades, "quantity > 0", name: "trades_quantity_positive"
    add_check_constraint :trades, "unit_price_cents > 0", name: "trades_unit_price_positive"
    add_check_constraint :trades, "fees_cents >= 0", name: "trades_fees_nonnegative"
  end
end
