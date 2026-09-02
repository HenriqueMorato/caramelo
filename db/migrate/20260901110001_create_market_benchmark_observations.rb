class CreateMarketBenchmarkObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :market_benchmark_observations do |t|
      t.references :market_benchmark, null: false, foreign_key: true
      t.date :observed_on, null: false
      t.decimal :value, precision: 28, scale: 12, null: false
      t.string :currency, null: false
      t.string :provider, null: false
      t.datetime :observed_at, null: false
      t.timestamps
    end

    add_index :market_benchmark_observations,
      %i[market_benchmark_id observed_on provider], unique: true, name: "index_market_benchmark_observations_uniqueness"
  end
end
