class AddReturnConventionToMarketBenchmarks < ActiveRecord::Migration[8.1]
  def change
    add_column :market_benchmarks, :return_convention, :string

    add_check_constraint :market_benchmarks,
      "return_convention IS NULL OR return_convention IN ('gross', 'net')",
      name: "market_benchmarks_return_convention"
  end
end
