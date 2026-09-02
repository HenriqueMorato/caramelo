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

  test "carries the latest benchmark value across weekend series dates" do
    friday = Date.new(2026, 8, 28)
    series = Data.define(:observations).new([
      Data.define(:date).new(friday), Data.define(:date).new(friday + 1), Data.define(:date).new(friday + 2)
    ])
    benchmark = MarketBenchmark.new(identifier: "SP500", name: "S&P 500", kind: "price")
    result = Performance::Benchmark::Result.new(
      benchmark:, from: friday, to: friday + 2,
      observations: [ MarketBenchmarkObservation.new(market_benchmark: benchmark, observed_on: friday, value: 100) ],
      first_observation: nil, last_observation: nil, return_ratio: BigDecimal("0"), status: :available
    )

    assert_equal [ 0.0, 0.0, 0.0 ], Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ]).first[:values]
  end

  test "leaves dates before the first benchmark observation unavailable" do
    friday = Date.new(2026, 8, 28)
    series = Data.define(:observations).new([ Data.define(:date).new(friday - 1), Data.define(:date).new(friday) ])
    benchmark = MarketBenchmark.new(identifier: "SP500", name: "S&P 500", kind: "price")
    result = Performance::Benchmark::Result.new(
      benchmark:, from: friday, to: friday,
      observations: [ MarketBenchmarkObservation.new(market_benchmark: benchmark, observed_on: friday, value: 100) ],
      first_observation: nil, last_observation: nil, return_ratio: BigDecimal("0"), status: :available
    )

    assert_nil Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ]).first[:values].first
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
