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
    Rails.cache.clear
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

  test "reports missing FX against the selected reporting currency" do
    users(:owner).update!(reporting_currency: "EUR")

    report = MarketData::HealthReport.for(current_market_price_service: CurrentPriceService.new)

    issue = report.issues.find { |item| item.code == :missing_exchange_rate }
    assert_includes issue.details, "USD/EUR"
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

  test "reports a current price as updating while its refresh state is active" do
    instrument = instruments(:voo_arcx)
    RefreshStatus::State.write(
      scope: "current_market_price:#{instrument.id}", status: "running",
      started_at: Time.current, total_count: 1
    )
    service = CurrentPriceService.new

    report = MarketData::HealthReport.for(owner: users(:owner), current_market_price_service: service)
    entry = report.entries.find { |candidate| candidate.target.kind == :current_price }

    assert_equal :updating, entry.status
    refute_predicate entry, :actionable?
    refute_predicate entry, :quote_reset_needed?
  end

  test "does not report an expired refresh marker as updating" do
    instrument = instruments(:voo_arcx)
    expired = RefreshStatus::State.new(
      scope: "current_market_price:#{instrument.id}", run_id: "expired", status: "running",
      started_at: 11.minutes.ago, finished_at: nil, updated_at: 11.minutes.ago,
      error_class: nil, error_message: nil, processed_count: 0, total_count: 1
    )

    report = nil
    with_stubbed_method(RefreshStatus::State, :read, ->(scope) {
      scope == "current_market_price:#{instrument.id}" ? expired : nil
    }) do
      report = MarketData::HealthReport.for(owner: users(:owner), current_market_price_service: CurrentPriceService.new)
    end
    entry = report.entries.find { |candidate| candidate.target.kind == :current_price }

    refute_equal :updating, entry.status
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name) { |*args, **kwargs| replacement.call(*args, **kwargs) }
    yield
  ensure
    object.define_singleton_method(method_name) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  test "builds normalized entries from issues" do
    issue = MarketData::HealthReport::Issue.new(
      code: :stale_current_price,
      severity: :warning,
      subject: instruments(:voo_arcx),
      details: "stale"
    )

    result = MarketData::HealthReport::Result.new(checked_at: Time.current, issues: [ issue ])
    entry = result.entries.first

    assert_equal :current_price, entry.target.kind
    assert_equal :stale, entry.status
    assert_equal [ :retry ], entry.actions
    assert_predicate entry, :actionable?
  end

  test "maps each recoverable issue to its target kind" do
    subjects = {
      missing_daily_close: "VOO",
      missing_exchange_rate: "USD",
      missing_benchmark_data: "S&P",
      unknown_issue: "Portfolio"
    }
    issues = subjects.map do |code, subject|
      MarketData::HealthReport::Issue.new(code:, severity: :warning, subject:, details: "missing")
    end

    result = MarketData::HealthReport::Result.new(checked_at: Time.current, issues:)

    assert_equal %i[daily_closing_prices historical_exchange_rates benchmark_observations portfolio_performance],
      result.entries.map { |entry| entry.target.kind }
  end

  test "builds issues from normalized entries" do
    entry = MarketData::HealthReport::Entry.new(
      code: :portfolio_performance,
      target: MarketData::Target.new(kind: :portfolio_performance),
      subject: "Portfolio performance",
      status: :missing,
      severity: :error,
      label: "Portfolio performance",
      description: "history is missing",
      observed_on: nil,
      fetched_at: nil,
      covered_range: nil,
      missing_range: nil,
      actions: [ :retry ]
    )

    result = MarketData::HealthReport::Result.new(checked_at: Time.current, entries: [ entry ])

    assert_equal :portfolio_performance, result.issues.first.code
    assert_equal "Portfolio performance", result.issues.first.subject
    assert_equal "history is missing", result.issues.first.details
  end
end
