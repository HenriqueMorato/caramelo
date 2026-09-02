class CreateMarketBenchmarks < ActiveRecord::Migration[8.1]
  def change
    create_table :market_benchmarks do |t|
      t.string :identifier, null: false
      t.string :name, null: false
      t.string :kind, null: false
      t.string :currency, null: false
      t.string :provider, null: false
      t.timestamps
    end

    add_index :market_benchmarks, :identifier, unique: true
  end
end
