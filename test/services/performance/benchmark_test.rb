require "test_helper"

class Performance::BenchmarkTest < ActiveSupport::TestCase
  setup do
    MarketBenchmarkObservation.delete_all
    MarketBenchmark.delete_all
    @from = Date.new(2026, 8, 26)
    @to = Date.new(2026, 8, 28)
  end

  test "calculates a price benchmark return from its endpoint observations" do
    benchmark = create_benchmark(kind: "price")
    create_observation(benchmark, @from, "100")
    create_observation(benchmark, @to, "110")

    result = Performance::Benchmark.for(benchmark:, from: @from, to: @to)

    assert_predicate result, :available?
    assert_equal BigDecimal("0.1"), result.return_ratio
    assert_equal @from, result.first_observation.observed_on
    assert_equal @to, result.last_observation.observed_on
    assert_equal [ BigDecimal("0"), BigDecimal("0.1") ], result.cumulative_return_values
  end

  test "compounds daily rate observations" do
    benchmark = create_benchmark(identifier: "CDI", kind: "rate")
    create_observation(benchmark, @from, "0.01")
    create_observation(benchmark, @to, "0.02")

    result = Performance::Benchmark.for(benchmark:, from: @from, to: @to)

    assert_equal BigDecimal("0.0302"), result.return_ratio
    assert_equal [ BigDecimal("0.01"), BigDecimal("0.0302") ], result.cumulative_return_values
  end

  test "applies B3 truncation when calculating CDI return" do
    benchmark = create_benchmark(identifier: "CDI", kind: "rate")
    create_observation(benchmark, @from, "0.00055131")
    create_observation(benchmark, @to, "0.00051660")

    result = Performance::Benchmark.for(benchmark:, from: @from, to: @to)

    assert_equal BigDecimal("0.00106819"), result.return_ratio
  end

  test "reports missing when fewer than two observations exist" do
    benchmark = create_benchmark
    create_observation(benchmark, @from, "100")

    result = Performance::Benchmark.for(benchmark:, from: @from, to: @to)

    assert_predicate result, :missing?
    assert_nil result.return_ratio
    assert_empty result.cumulative_return_values
  end

  test "rejects invalid ranges" do
    benchmark = create_benchmark

    assert_raises(ArgumentError) { Performance::Benchmark.for(benchmark:, from: @to, to: @from) }
    assert_raises(ArgumentError) { Performance::Benchmark.for(benchmark:, from: @from, to: Date.current + 1) }
  end

  private

  def create_benchmark(identifier: "IBOV", kind: "price")
    MarketBenchmark.create!(identifier:, name: identifier, kind:, currency: "BRL", provider: "bacen", provider_identifier: identifier)
  end

  def create_observation(benchmark, date, value)
    benchmark.observations.create!(observed_on: date, value:, currency: benchmark.currency, provider: "bacen", observed_at: Time.current)
  end
end
