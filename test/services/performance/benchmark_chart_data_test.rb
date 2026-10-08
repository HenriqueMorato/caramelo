require "test_helper"

class Performance::BenchmarkChartDataTest < ActiveSupport::TestCase
  test "maps available benchmark returns onto series dates" do
    observation = Data.define(:date).new(Date.new(2026, 8, 27))
    series = Data.define(:observations).new([ observation ])
    benchmark = Data.define(:identifier, :name, :observations) do
      def persisted? = false
    end.new("IBOV", "Ibovespa", [])
    result = Data.define(:status, :observations) do
      def available? = status == :available
      def missing? = status == :missing
      def cumulative_return_values = [ BigDecimal("0.05") ]
    end.new(:available, [ Data.define(:observed_on).new(observation.date) ])

    data = Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ])

    assert_equal [ { identifier: "IBOV", label: "Ibovespa", values: [ 5.0 ] } ], data
  end

  test "uses the compatibility chart path for result objects without chart helpers" do
    friday = Date.new(2026, 8, 28)
    monday = Date.new(2026, 8, 31)
    benchmark = MarketBenchmark.create!(identifier: "FALLBACK", name: "Fallback benchmark", kind: "price",
      currency: "USD", provider: "test", provider_identifier: "FALLBACK")
    benchmark.observations.create!(observed_on: friday, value: 100,
      currency: "USD", provider: "test", observed_at: Time.current)
    monday_observation = benchmark.observations.create!(observed_on: monday, value: 110,
      currency: "USD", provider: "test", observed_at: Time.current)
    result_class = Struct.new(:status, :observations) do
      def available? = status == :available
      def missing? = status == :missing
      def cumulative_return_values = [ BigDecimal("0"), BigDecimal("0.1") ]
    end
    result = result_class.new(:available, [ monday_observation ])
    series = Data.define(:observations).new([ friday + 1, friday + 2, monday ].map { |date| Data.define(:date).new(date) })

    data = Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ]).first

    assert_equal [ 0.0, 0.0, 10.0 ], data[:values]
  end

  test "keeps a stale compatibility anchor out of the chart" do
    start = Date.new(2026, 8, 31)
    benchmark = MarketBenchmark.create!(identifier: "FALLBACK_STALE", name: "Stale fallback", kind: "price",
      currency: "USD", provider: "test", provider_identifier: "FALLBACK_STALE")
    benchmark.observations.create!(observed_on: start - 30, value: 100,
      currency: "USD", provider: "test", observed_at: Time.current)
    observation = benchmark.observations.create!(observed_on: start + 1, value: 110,
      currency: "USD", provider: "test", observed_at: Time.current)
    result_class = Struct.new(:status, :observations) do
      def available? = status == :available
      def missing? = false
      def cumulative_return_values = [ BigDecimal("0") ]
    end
    result = result_class.new(:available, [ observation ])
    series = Data.define(:observations).new([ Data.define(:date).new(start), Data.define(:date).new(start + 1) ])

    data = Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ]).first

    assert_nil data[:values].first
    assert_in_delta 0.0, data[:values].last, 0.001
  end

  test "does not anchor a compatibility result that starts on a real observation" do
    start = Date.new(2026, 8, 31)
    benchmark = MarketBenchmark.create!(identifier: "FALLBACK_SAME_DAY", name: "Same-day fallback", kind: "price",
      currency: "USD", provider: "test", provider_identifier: "FALLBACK_SAME_DAY")
    observation = benchmark.observations.create!(observed_on: start, value: 100,
      currency: "USD", provider: "test", observed_at: Time.current)
    result_class = Struct.new(:status, :observations) do
      def available? = status == :available
      def missing? = false
      def cumulative_return_values = [ BigDecimal("0") ]
    end
    result = result_class.new(:available, [ observation ])
    series = Data.define(:observations).new([ Data.define(:date).new(start) ])

    data = Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ]).first

    assert_equal [ 0.0 ], data[:values]
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

    assert_in_delta 0.0, values[0], 0.001
    assert_in_delta 0.0, values[1], 0.001
    assert_in_delta 2.0, values[2], 0.001
    assert_in_delta 5.06, values[3], 0.001
  end

  test "renders a short weekend range with one in-range benchmark observation" do
    friday = Date.new(2026, 7, 31)
    monday = Date.new(2026, 8, 3)
    benchmark = MarketBenchmark.create!(identifier: "SHORTWEEKEND", name: "Short weekend", kind: "price",
      currency: "USD", provider: "test", provider_identifier: "SHORTWEEKEND")
    [ [ friday, 100 ], [ monday, 101 ] ].each do |date, value|
      benchmark.observations.create!(observed_on: date, value:, currency: "USD", provider: "test", observed_at: Time.current)
    end
    series = Data.define(:observations).new((friday + 1..monday).map { |date| Data.define(:date).new(date) })
    result = Performance::Benchmark.for(benchmark:, from: friday + 1, to: monday)

    data = Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ]).first

    assert_equal [ 0.0, 0.0, 1.0 ], data[:values]
  end

  test "does not anchor when the chart starts on an observation date" do
    monday = Date.new(2026, 8, 31)
    benchmark = MarketBenchmark.create!(identifier: "NOANCHOR", name: "No anchor", kind: "price",
      currency: "USD", provider: "test", provider_identifier: "NOANCHOR")
    [ [ monday - 1, 100 ], [ monday, 101 ], [ monday + 1, 102 ] ].each do |date, value|
      benchmark.observations.create!(observed_on: date, value:, currency: "USD", provider: "test", observed_at: Time.current)
    end
    series = Data.define(:observations).new([ monday, monday + 1 ].map { |date| Data.define(:date).new(date) })
    result = Performance::Benchmark.for(benchmark:, from: monday, to: monday + 1)

    values = Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ]).first[:values]

    assert_in_delta 0.0, values[0], 0.001
    assert_in_delta 0.9901, values[1], 0.001
  end

  test "does not carry an observation beyond the historical safety window" do
    start = Date.new(2026, 6, 1)
    benchmark = MarketBenchmark.create!(identifier: "STALECHART", name: "Stale chart", kind: "price",
      currency: "USD", provider: "test", provider_identifier: "STALECHART")
    [ [ start - 30, 100 ], [ start + 29, 110 ], [ start + 30, 111 ] ].each do |date, value|
      benchmark.observations.create!(observed_on: date, value:, currency: "USD", provider: "test", observed_at: Time.current)
    end
    series = Data.define(:observations).new((start..start + 30).map { |date| Data.define(:date).new(date) })
    result = Performance::Benchmark.for(benchmark:, from: start, to: start + 30)

    values = Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ]).first[:values]

    assert_nil values.first
    assert_in_delta 0.0, values[29], 0.001
  end

  test "returns no values when the chart series is empty" do
    benchmark = MarketBenchmark.create!(identifier: "EMPTYCHART", name: "Empty chart", kind: "price",
      currency: "USD", provider: "test", provider_identifier: "EMPTYCHART")
    observation = benchmark.observations.create!(observed_on: Date.current - 1, value: 100,
      currency: "USD", provider: "test", observed_at: Time.current)
    result = Data.define(:status, :observations, :cumulative_return_values) do
      def available? = status == :available
      def missing? = false
    end.new(:available, [ observation ], [ BigDecimal("0") ])

    assert_equal [ { identifier: "EMPTYCHART", label: "Empty chart", values: [] } ],
      Performance::BenchmarkChartData.for(series: Data.define(:observations).new([]), benchmark_results: [ [ benchmark, result ] ])
  end

  test "skips unavailable benchmark results" do
    series = Data.define(:observations).new([])
    benchmark = Data.define(:identifier, :name, :observations) do
      def persisted? = false
    end.new("IBOV", "Ibovespa", [])
    result = Struct.new(:status, :observations) do
      def available? = status == :available
      def missing? = false
    end.new(:unavailable, [])

    assert_empty Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ])
  end

  test "skips a missing benchmark with fewer than two observations" do
    date = Date.current - 1
    series = Data.define(:observations).new([ Data.define(:date).new(date) ])
    benchmark = Data.define(:identifier, :name, :observations) do
      def persisted? = false
    end.new("SHORT", "Short benchmark", [])
    result = Data.define(:status, :observations) do
      def available? = false
      def missing? = true
    end.new(:missing, [ Data.define(:observed_on).new(date) ])

    assert_empty Performance::BenchmarkChartData.for(series:, benchmark_results: [ [ benchmark, result ] ])
  end
end
