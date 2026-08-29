class CreateDailyClosingPrices < ActiveRecord::Migration[8.1]
  def change
    create_table :daily_closing_prices do |t|
      t.references :instrument, null: false, foreign_key: true
      t.date :trading_date, null: false
      t.decimal :close_price, precision: 28, scale: 8, null: false
      t.string :currency, limit: 3, null: false
      t.string :provider, limit: 64, null: false
      t.datetime :observed_at, null: false

      t.timestamps
    end

    add_index :daily_closing_prices, %i[instrument_id trading_date provider], unique: true,
      name: "index_daily_closing_prices_on_instrument_date_provider"
    add_check_constraint :daily_closing_prices, "close_price > 0", name: "daily_closing_prices_close_positive"
  end
end
