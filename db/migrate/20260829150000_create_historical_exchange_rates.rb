class CreateHistoricalExchangeRates < ActiveRecord::Migration[8.1]
  def change
    create_table :historical_exchange_rates do |t|
      t.string :base_currency, limit: 3, null: false
      t.string :quote_currency, limit: 3, null: false
      t.date :rate_date, null: false
      t.decimal :rate, precision: 28, scale: 12, null: false
      t.string :provider, limit: 64, null: false
      t.datetime :observed_at, null: false
      t.datetime :fetched_at, null: false

      t.timestamps
    end

    add_index :historical_exchange_rates, %i[base_currency quote_currency rate_date provider], unique: true,
      name: "index_historical_exchange_rates_on_pair_date_provider"
    add_check_constraint :historical_exchange_rates, "rate > 0", name: "historical_exchange_rates_rate_positive"
    add_check_constraint :historical_exchange_rates, "base_currency <> quote_currency",
      name: "historical_exchange_rates_currencies_distinct"
  end
end
