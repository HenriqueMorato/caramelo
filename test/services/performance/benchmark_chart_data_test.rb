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

  test "uses the prior trading observation when a chart starts on a weekend" do
    friday = Date.new(2026, 8, 28)
    monday = Date.new(2026, 8, 31)
    benchmark = MarketBenchmark.create!(identifier: "WEEKEND", name: "Weekend benchmark", kind: "price",
      currency: "USD", provider: "test", provider_identifier: "WEEKEND")
    [ [ friday, 100 ], [ monday, 101 ], [ monday + 1, 102 ] ].each do |date, value|
      benchmark.observations.create!(observed_on: date, value:, currency: "USD", provider: "test", observed_at: Time.current)
    end
    series = Data.define(:observations).new((friday + 1..monday + 1).map { |date| Data.define(:date).new(date) })
    result = Performance::Benchmark.for(benchmark:, from: friday + 1, to: monday + 1)

    data = Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ]).first

    assert_equal [ 0.0, 0.0, 1.0, 2.0 ], data[:values]
  end

  test "compounds rate benchmarks from the prior trading observation" do
    friday = Date.new(2026, 8, 28)
    monday = Date.new(2026, 8, 31)
    benchmark = MarketBenchmark.create!(identifier: "RATEWEEKEND", name: "Rate weekend", kind: "rate",
      currency: "BRL", provider: "test", provider_identifier: "RATEWEEKEND")
    [ [ friday, "0.01" ], [ monday, "0.02" ], [ monday + 1, "0.03" ] ].each do |date, value|
      benchmark.observations.create!(observed_on: date, value:, currency: "BRL", provider: "test", observed_at: Time.current)
    end
    series = Data.define(:observations).new((friday + 1..monday + 1).map { |date| Data.define(:date).new(date) })
    result = Performance::Benchmark.for(benchmark:, from: friday + 1, to: monday + 1)

    values = Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ]).first[:values]

    assert_in_delta 1.0, values[0], 0.001
    assert_in_delta 1.0, values[1], 0.001
    assert_in_delta 3.02, values[2], 0.001
    assert_in_delta 6.1106, values[3], 0.001
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
