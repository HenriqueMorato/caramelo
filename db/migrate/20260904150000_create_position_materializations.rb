class CreatePositionMaterializations < ActiveRecord::Migration[8.1]
  def change
    create_table :position_materializations do |t|
      t.references :user, null: false, foreign_key: true
      t.references :instrument, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.decimal :quantity, precision: 50, scale: 24, null: false, default: 0
      t.decimal :cost_basis_amount, precision: 50, scale: 24, null: false, default: 0
      t.decimal :average_unit_cost, precision: 50, scale: 24, null: false, default: 0
      t.decimal :realized_gain_amount, precision: 50, scale: 24, null: false, default: 0
      t.integer :source_trade_id
      t.datetime :calculated_at
      t.string :error_class
      t.text :error_message

      t.timestamps
    end

    add_index :position_materializations, %i[user_id instrument_id], unique: true,
      name: "index_position_materializations_on_user_and_instrument"
    add_check_constraint :position_materializations,
      "status IN ('pending', 'refreshing', 'complete', 'failed')",
      name: "position_materializations_status"
  end
end
