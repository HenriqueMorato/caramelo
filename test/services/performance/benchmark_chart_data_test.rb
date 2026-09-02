require "test_helper"

class Performance::BenchmarkChartDataTest < ActiveSupport::TestCase
  test "maps available benchmark returns onto series dates" do
    observation = Data.define(:date).new(Date.new(2026, 8, 27))
    series = Data.define(:observations).new([ observation ])
    benchmark = Data.define(:identifier, :name).new("IBOV", "Ibovespa")
    result = Data.define(:status, :observations) do
      def available? = status == :available
      def cumulative_return_values = [ BigDecimal("0.05") ]
    end.new(:available, [ Data.define(:observed_on).new(observation.date) ])

    data = Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ])

    assert_equal [ { identifier: "IBOV", label: "Ibovespa", values: [ 5.0 ] } ], data
  end

  test "skips unavailable benchmark results" do
    series = Data.define(:observations).new([])
    benchmark = Data.define(:identifier, :name).new("IBOV", "Ibovespa")
    result = Struct.new(:status) do
      def available? = status == :available
    end.new(:missing)

    assert_empty Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ])
  end
end
