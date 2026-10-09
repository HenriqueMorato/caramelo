require "test_helper"

class Performance::BenchmarkTest < ActiveSupport::TestCase
  setup do
    MarketBenchmarkObservation.delete_all
    MarketBenchmark.delete_all
    HistoricalExchangeRate.delete_all
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

  test "reports an index as missing when its source has a long internal gap" do
    from = Date.new(2026, 1, 1)
    to = Date.new(2026, 7, 1)
    benchmark = create_benchmark(identifier: "ACWI_GAP", kind: "total_return")
    create_observation(benchmark, from + 1, "100")
    create_observation(benchmark, to, "112")

    result = Performance::Benchmark.for(benchmark:, from:, to:)

    assert_predicate result, :missing?
    assert_nil result.return_ratio
  end

  test "reports an index as missing when its source ends before the selected period" do
    from = Date.new(2026, 1, 1)
    to = Date.new(2026, 7, 1)
    benchmark = create_benchmark(identifier: "ACWI_TRAILING", kind: "total_return")
    create_observation(benchmark, from + 1, "100")
    create_observation(benchmark, to - 8, "112")

    result = Performance::Benchmark.for(benchmark:, from:, to:)

    assert_predicate result, :missing?
    assert_nil result.return_ratio
  end

  test "reports an index as missing when the selected period predates its source" do
    from = Date.new(2011, 7, 20)
    to = Date.new(2011, 7, 28)
    benchmark = create_benchmark(identifier: "ACWI_INCEPTION", kind: "total_return", provider: "yahoo_finance",
      provider_identifier: "IMID.L")
    create_observation(benchmark, Date.new(2011, 7, 27), "100")
    create_observation(benchmark, to, "102")

    result = Performance::Benchmark.for(benchmark:, from:, to:)

    assert_predicate result, :missing?
    assert_nil result.return_ratio
  end

  test "uses the prior eligible index observation for summary and chart parity" do
    from = Date.new(2026, 8, 29)
    to = Date.new(2026, 9, 1)
    benchmark = create_benchmark(identifier: "WEEKEND_INDEX")
    create_observation(benchmark, Date.new(2026, 8, 28), "100")
    create_observation(benchmark, Date.new(2026, 8, 31), "101")
    create_observation(benchmark, to, "102")

    result = Performance::Benchmark.for(benchmark:, from:, to:)

    assert_equal BigDecimal("0.02"), result.return_ratio
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

  test "converts a rate benchmark through historical FX before compounding" do
    benchmark = create_benchmark(identifier: "CDI_FX", kind: "rate", currency: "BRL")
    create_observation(benchmark, @from, "0.01")
    create_observation(benchmark, @to, "0.02")
    rates = { @from => "0.2", @to => "0.25" }

    result = Performance::Benchmark.for(
      benchmark:, from: @from, to: @to, reporting_currency: "USD", exchange_rate_service: FxService.new(rates:)
    )

    assert_equal BigDecimal("0.28775"), result.return_ratio
    assert_equal "USD", result.calculation_observations.last.currency
  end

  test "reports a rate benchmark as missing when a conversion rate is unavailable" do
    benchmark = create_benchmark(identifier: "CDI_MISSING_FX", kind: "rate", currency: "BRL")
    create_observation(benchmark, @from, "0.01")
    create_observation(benchmark, @to, "0.02")

    result = Performance::Benchmark.for(
      benchmark:, from: @from, to: @to, reporting_currency: "USD", exchange_rate_service: FxService.new
    )

    assert_predicate result, :missing?
    assert_nil result.return_ratio
  end

  test "keeps a foreign rate summary aligned with its anchored weekend chart" do
    from = Date.new(2026, 8, 29)
    to = Date.new(2026, 9, 1)
    benchmark = create_benchmark(identifier: "CDI_WEEKEND_FX", kind: "rate", currency: "BRL")
    create_observation(benchmark, Date.new(2026, 8, 28), "0.01")
    create_observation(benchmark, Date.new(2026, 8, 31), "0.02")
    create_observation(benchmark, to, "0.03")
    rates = {
      Date.new(2026, 8, 28) => "0.2",
      Date.new(2026, 8, 31) => "0.25",
      to => "0.3"
    }

    result = Performance::Benchmark.for(
      benchmark:, from:, to:, reporting_currency: "USD", exchange_rate_service: FxService.new(rates:)
    )

    assert_in_delta result.return_ratio, result.chart_cumulative_return_values.last, BigDecimal("0.00000001")
  end

  test "keeps an index available when only inverse historical FX rows exist" do
    benchmark = create_benchmark(identifier: "ACWI_INVERSE", kind: "total_return", currency: "USD")
    create_observation(benchmark, @from, "100")
    create_observation(benchmark, @to, "110")
    [ [ @from, "0.2" ], [ @to, "0.25" ] ].each do |date, rate|
      HistoricalExchangeRate.create!(base_currency: "BRL", quote_currency: "USD", rate_date: date, rate:,
        provider: MarketData::YahooFinance::FX_CONFIGURATION.identifier, observed_at: Time.current, fetched_at: Time.current)
    end

    result = Performance::Benchmark.for(benchmark:, from: @from, to: @to, reporting_currency: "BRL")

    assert_predicate result, :available?
    assert_equal BigDecimal("-0.12"), result.return_ratio
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

  test "does not add an unavailable foreign-rate chart anchor" do
    from = Date.new(2026, 8, 29)
    to = Date.new(2026, 9, 1)
    benchmark = create_benchmark(identifier: "CDI_ANCHOR_FX", kind: "rate", currency: "BRL")
    create_observation(benchmark, Date.new(2026, 8, 28), "0.01")
    create_observation(benchmark, Date.new(2026, 8, 31), "0.02")
    create_observation(benchmark, to, "0.03")

    result = Performance::Benchmark.for(
      benchmark:, from:, to:, reporting_currency: "USD",
      exchange_rate_service: FxService.new(rates: { Date.new(2026, 8, 31) => "0.25", to => "0.3" })
    )

    assert_equal [ Date.new(2026, 8, 31), to ], result.chart_observations.map(&:observed_on)
  end

  test "rejects invalid ranges" do
    benchmark = create_benchmark

    assert_raises(ArgumentError) { Performance::Benchmark.for(benchmark:, from: @to, to: @from) }
    assert_raises(ArgumentError) { Performance::Benchmark.for(benchmark:, from: @from, to: Date.current + 1) }
  end

  private

  def create_benchmark(identifier: "IBOV", kind: "price", currency: "BRL", provider: "bacen", provider_identifier: identifier)
    attributes = { identifier:, name: identifier, kind:, currency:, provider:, provider_identifier: }
    attributes[:return_convention] = "net" if kind == "total_return"
    MarketBenchmark.create!(attributes)
  end

  def create_observation(benchmark, date, value)
    benchmark.observations.create!(observed_on: date, value:, currency: benchmark.currency,
      provider: benchmark.provider, observed_at: Time.current)
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
