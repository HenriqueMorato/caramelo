require "test_helper"

class MarketData::HealthReportTest < ActiveSupport::TestCase
  Lookup = Data.define(:status) do
    def missing? = status == :missing
    def stale? = status == :stale
  end

  class CurrentPriceService
    def initialize(status: :fresh)
      @status = status
    end

    def read(instrument:)
      Lookup.new(@status)
    end
  end

  setup do
    MarketBenchmarkObservation.delete_all
    MarketBenchmark.delete_all
  end

  test "reports missing and stale data needed by traded instruments" do
    instrument = instruments(:voo_arcx)
    MarketBenchmark.create!(identifier: "HEALTHSP", name: "Health S&P", kind: :price, currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^GSPC")

    report = MarketData::HealthReport.for(
      owner: users(:owner), current_market_price_service: CurrentPriceService.new(status: :stale),
      today: Date.new(2026, 9, 2)
    )

    assert_equal %i[stale_current_price missing_daily_close missing_exchange_rate missing_benchmark_data], report.issues.map(&:code)
    assert_equal 4, report.warnings.size
    refute report.healthy?
  end

  test "labels instruments and benchmarks without exposing record inspection" do
    instrument = instruments(:voo_arcx)
    benchmark = MarketBenchmark.create!(identifier: "HEALTHSP", name: "Health S&P", kind: :price, currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^GSPC")
    report = MarketData::HealthReport.for(
      owner: users(:owner), current_market_price_service: CurrentPriceService.new(status: :missing)
    )

    assert_equal "VOO · Vanguard S&P 500 ETF", report.issues.first.subject_label
    benchmark_issue = report.issues.find { |issue| issue.subject == benchmark }
    assert_equal "Health S&P (HEALTHSP)", benchmark_issue.subject_label
  end

  test "reports healthy when all required records exist" do
    instrument = instruments(:voo_arcx)
    DailyClosingPrice.create!(instrument:, trading_date: Date.new(2026, 9, 1), close_price: 620,
      currency: instrument.currency, provider: "yahoo_finance", observed_at: Time.current)
    HistoricalExchangeRate.create!(base_currency: "USD", quote_currency: "BRL", rate_date: Date.new(2026, 9, 1),
      rate: 5, provider: "bcb", observed_at: Time.current, fetched_at: Time.current)
    benchmark = MarketBenchmark.create!(identifier: "HEALTHSP", name: "Health S&P", kind: :price, currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^GSPC")
    MarketBenchmarkObservation.create!(market_benchmark: benchmark, observed_on: Date.new(2026, 9, 1), value: 1,
      currency: "USD", provider: "yahoo_finance", observed_at: Time.current)

    report = MarketData::HealthReport.for(
      owner: users(:owner), current_market_price_service: CurrentPriceService.new,
      today: Date.new(2026, 9, 2)
    )

    assert report.healthy?
    assert_empty report.issues
  end

  test "reports missing current prices and ignores same-currency exchange rates" do
    instrument = instruments(:petr4_bvmf)
    User.owner.trades.create!(instrument:, side: :buy, traded_on: Date.current, quantity: 1, unit_price: 10,
      fees_cents: 0, currency: instrument.currency)

    report = MarketData::HealthReport.for(
      owner: users(:owner), current_market_price_service: CurrentPriceService.new(status: :missing)
    )

    assert report.errors.any? { |issue| issue.code == :missing_current_price }
    assert report.warnings.any? { |issue| issue.code == :missing_exchange_rate }
    refute report.issues.any? { |issue| issue.subject == "BRL" && issue.code == :missing_exchange_rate }
  end

  test "orders errors before warnings" do
    instrument = instruments(:petr4_bvmf)
    User.owner.trades.create!(instrument:, side: :buy, traded_on: Date.current, quantity: 1, unit_price: 10,
      fees_cents: 0, currency: instrument.currency)

    report = MarketData::HealthReport.for(
      owner: users(:owner), current_market_price_service: CurrentPriceService.new(status: :missing)
    )

    assert_equal :error, report.issues.first.severity
    first_warning = report.issues.index { |issue| issue.severity == :warning }
    assert first_warning
    assert report.issues.first(first_warning).all? { |issue| issue.severity == :error }
    assert report.issues.drop(first_warning).all? { |issue| issue.severity == :warning }
    assert_predicate report, :current_prices_need_refresh?
  end

  test "does not refresh current prices for historical-only issues" do
    report = MarketData::HealthReport::Result.new(
      checked_at: Time.current,
      issues: [ MarketData::HealthReport::Issue.new(
        code: :missing_benchmark_data, severity: :warning, subject: "CDI", details: "missing"
      ) ]
    )

    refute_predicate report, :current_prices_need_refresh?
  end
end
