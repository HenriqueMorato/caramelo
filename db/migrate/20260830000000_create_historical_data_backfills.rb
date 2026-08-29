class CreateHistoricalDataBackfills < ActiveRecord::Migration[8.1]
  def change
    create_table :historical_data_backfills do |t|
      t.references :instrument, null: false, foreign_key: true
      t.string :currency, null: false
      t.date :from_date, null: false
      t.integer :generation, null: false, default: 1

      t.timestamps
    end

    add_index :historical_data_backfills, [ :instrument_id, :currency ], unique: true
  end
end
