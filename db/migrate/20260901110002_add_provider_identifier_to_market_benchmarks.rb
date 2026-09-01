class AddProviderIdentifierToMarketBenchmarks < ActiveRecord::Migration[8.1]
  def change
    add_column :market_benchmarks, :provider_identifier, :string
    change_column_null :market_benchmarks, :provider_identifier, false
  end
end
