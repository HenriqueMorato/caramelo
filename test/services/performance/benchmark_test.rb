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

  test "calculates a total-return index from its endpoint observations" do
    benchmark = create_benchmark(identifier: "ACWI_IMI_NET", kind: "total_return", currency: "USD")
    create_observation(benchmark, @from, "100")
    create_observation(benchmark, @to, "112")

    result = Performance::Benchmark.for(benchmark:, from: @from, to: @to)

    assert_predicate result, :available?
    assert_equal BigDecimal("0.12"), result.return_ratio
    assert_equal [ BigDecimal("0"), BigDecimal("0.12") ], result.cumulative_return_values
  end

  test "converts an index through historical FX before calculating its return" do
    benchmark = create_benchmark(identifier: "ACWI_FX", kind: "total_return", currency: "USD")
    create_observation(benchmark, @from, "100")
    create_observation(benchmark, @to, "110")
    rates = { @from => "5", @to => "5.5" }

    result = Performance::Benchmark.for(
      benchmark:, from: @from, to: @to, reporting_currency: "BRL", exchange_rate_service: FxService.new(rates:)
    )

    assert_equal BigDecimal("0.21"), result.return_ratio
    assert_equal BigDecimal("500"), result.calculation_observations.first.value
    assert_equal "BRL", result.calculation_observations.last.currency
  end

  test "reports an index as missing when a selected reporting-currency rate is unavailable" do
    benchmark = create_benchmark(identifier: "ACWI_MISSING_FX", kind: "total_return", currency: "USD")
    create_observation(benchmark, @from, "100")
    create_observation(benchmark, @to, "110")

    result = Performance::Benchmark.for(
      benchmark:, from: @from, to: @to, reporting_currency: "BRL", exchange_rate_service: FxService.new
    )

    assert_predicate result, :missing?
    assert_nil result.return_ratio
    assert_empty result.chart_observations
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

  test "reports missing when no observations exist" do
    benchmark = create_benchmark(identifier: "EMPTY")

    result = Performance::Benchmark.for(benchmark:, from: @from, to: @to)

    assert_predicate result, :missing?
    assert_empty result.chart_observations
  end

  test "does not add an unavailable currency-converted chart anchor" do
    benchmark = create_benchmark(identifier: "ACWI_ANCHOR", kind: "total_return", currency: "USD")
    create_observation(benchmark, @from - 1, "99")
    create_observation(benchmark, @from + 1, "100")
    create_observation(benchmark, @to, "110")
    rates = { @from + 1 => "5", @to => "5.5" }

    result = Performance::Benchmark.for(
      benchmark:, from: @from, to: @to, reporting_currency: "BRL", exchange_rate_service: FxService.new(rates:)
    )

    assert_predicate result, :available?
    assert_equal [ @from + 1, @to ], result.chart_observations.map(&:observed_on)
  end

  test "rejects invalid ranges" do
    benchmark = create_benchmark

    assert_raises(ArgumentError) { Performance::Benchmark.for(benchmark:, from: @to, to: @from) }
    assert_raises(ArgumentError) { Performance::Benchmark.for(benchmark:, from: @from, to: Date.current + 1) }
  end

  private

  def create_benchmark(identifier: "IBOV", kind: "price", currency: "BRL")
    attributes = { identifier:, name: identifier, kind:, currency:, provider: "bacen", provider_identifier: identifier }
    attributes[:return_convention] = "net" if kind == "total_return"
    MarketBenchmark.create!(attributes)
  end

  def create_observation(benchmark, date, value)
    benchmark.observations.create!(observed_on: date, value:, currency: benchmark.currency, provider: "bacen", observed_at: Time.current)
  end

  class FxService
    Rate = Data.define(:rate)

    def initialize(rates: {})
      @rates = rates
    end

    def read(base_currency:, quote_currency:, rate_date:)
      rate = @rates[rate_date]
      return HistoricalExchangeRate::Lookup.new(exchange_rate: nil, status: :missing, inverted: false) unless rate

      HistoricalExchangeRate::Lookup.new(
        exchange_rate: Rate.new(rate: BigDecimal(rate)), status: :available, inverted: false
      )
    end
  end
end
