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
    TradingCalendar.weekdays_between(Date.new(2026, 8, 12), Date.new(2026, 9, 1)).each do |date|
      DailyClosingPrice.create!(instrument:, trading_date: date, close_price: 620,
        currency: instrument.currency, provider: "yahoo_finance", observed_at: Time.current)
    end
    HistoricalExchangeRate.create!(base_currency: "USD", quote_currency: "BRL", rate_date: Date.new(2026, 8, 12),
      rate: 5, provider: "bcb", observed_at: Time.current, fetched_at: Time.current)
    benchmark = MarketBenchmark.create!(identifier: "HEALTHSP", name: "Health S&P", kind: :price, currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^GSPC")
    TradingCalendar.weekdays_between(Date.new(2026, 8, 12), Date.new(2026, 9, 1)).each do |date|
      MarketBenchmarkObservation.create!(market_benchmark: benchmark, observed_on: date, value: 1,
        currency: "USD", provider: "yahoo_finance", observed_at: Time.current)
    end

    report = MarketData::HealthReport.for(
      owner: users(:owner), current_market_price_service: CurrentPriceService.new,
      today: Date.new(2026, 9, 2)
    )

    assert report.healthy?
    assert_empty report.issues
  end

  test "compacts missing coverage dates into ranges" do
    coverage = MarketData::HealthReport::CoverageCalculator.for(
      required_dates: (Date.new(2026, 9, 1)..Date.new(2026, 9, 7)).to_a,
      observations: [
        DailyClosingPrice.new(trading_date: Date.new(2026, 9, 1)),
        DailyClosingPrice.new(trading_date: Date.new(2026, 9, 4))
      ]
    )

    assert_equal [ Date.new(2026, 9, 2)..Date.new(2026, 9, 3), Date.new(2026, 9, 5)..Date.new(2026, 9, 7) ],
      coverage.missing_ranges
    assert_predicate coverage, :partial?
  end

  test "carries a recent real observation across short closures" do
    friday = Date.new(2026, 9, 4)
    coverage = MarketData::HealthReport::CoverageCalculator.for(
      required_dates: (friday..friday + 3.days).to_a,
      observations: [ DailyClosingPrice.new(trading_date: friday) ],
      carry_forward: true
    )

    assert_predicate coverage, :complete?
    assert_empty coverage.missing_ranges
  end

  test "does not carry observations beyond the historical window" do
    date = Date.new(2026, 9, 12)
    coverage = MarketData::HealthReport::CoverageCalculator.for(
      required_dates: [ date ],
      observations: [ DailyClosingPrice.new(trading_date: date - 8.days) ],
      carry_forward: true
    )

    assert_predicate coverage, :missing?
    assert_equal [ date..date ], coverage.missing_ranges
  end

  test "returns an empty healthy coverage for no required dates" do
    coverage = MarketData::HealthReport::CoverageCalculator.for(required_dates: [], observations: [])

    assert_predicate coverage, :complete?
    refute_predicate coverage, :partial?
    assert_predicate coverage, :missing?
    assert_nil coverage.missing_range
  end

  test "reads observation timestamps from supported attribute names" do
    observation = Data.define(:observed_on, :observed_at).new(Date.current, Time.current)
    coverage = MarketData::HealthReport::CoverageCalculator.for(
      required_dates: [ Date.current ], observations: [ observation ]
    )

    assert_equal Date.current, coverage.latest_observed_on
    assert_equal observation.observed_at, coverage.latest_fetched_at
  end

  test "accepts an observation without a fetch timestamp" do
    observation = Struct.new(:observed_on).new(Date.current)
    coverage = MarketData::HealthReport::CoverageCalculator.for(
      required_dates: [ Date.current ], observations: [ observation ]
    )

    assert_nil coverage.latest_fetched_at
  end

  test "reports a failed current-price refresh with its error message" do
    instrument = instruments(:voo_arcx)
    failed = RefreshStatus::State.new(
      scope: "current_market_price:#{instrument.id}", run_id: "run", status: "failed",
      started_at: 1.minute.ago, finished_at: Time.current, updated_at: Time.current,
      error_class: "MarketPrice::ProviderFailure", error_message: "provider timeout",
      processed_count: 0, total_count: 1
    )

    report = nil
    with_stubbed_method(RefreshStatus::State, :read, ->(scope) {
      scope == "current_market_price:#{instrument.id}" ? failed : nil
    }) do
      report = MarketData::HealthReport.for(owner: users(:owner), current_market_price_service: CurrentPriceService.new)
    end

    entry = report.entries.find { |candidate| candidate.target.kind == :current_price }
    assert_equal :failed, entry.status
    assert_equal "provider timeout", entry.description
  end

  test "reports performance coverage while materialization is pending" do
    owner = users(:owner)
    materialization = PortfolioPerformanceMaterialization.for(user: owner, reporting_currency: owner.reporting_currency)
    materialization.request!(from: owner.trades.minimum(:traded_on), to: Date.current)

    report = MarketData::HealthReport.for(owner:, current_market_price_service: CurrentPriceService.new)

    entry = report.entries.find { |candidate| candidate.code == :portfolio_performance }
    assert_equal :updating, entry.status
  end

  test "reports missing performance coverage when materialization is complete but observations are absent" do
    owner = users(:owner)
    PortfolioPerformanceMaterialization.for(user: owner, reporting_currency: owner.reporting_currency)

    report = MarketData::HealthReport.for(owner:, current_market_price_service: CurrentPriceService.new)

    entry = report.entries.find { |candidate| candidate.code == :portfolio_performance }
    assert_equal :missing, entry.status
    assert_equal :warning, entry.severity
  end

  test "reports healthy and partial performance coverage" do
    owner = users(:owner)
    first_date = owner.trades.minimum(:traded_on)
    materialization = PortfolioPerformanceMaterialization.for(user: owner, reporting_currency: owner.reporting_currency)

    (first_date..Date.current).each do |date|
      PortfolioPerformanceObservation.create!(user: owner, reporting_currency: owner.reporting_currency,
        observed_on: date, generated_at: Time.current, status: :available,
        source_generation: materialization.source_generation, market_value_amount: "100", net_cash_flow_amount: "0")
    end
    healthy = MarketData::HealthReport.for(owner:, current_market_price_service: CurrentPriceService.new)
    assert_equal :healthy, healthy.entries.find { |entry| entry.code == :portfolio_performance }.status

    PortfolioPerformanceObservation.where(user: owner, reporting_currency: owner.reporting_currency, observed_on: first_date).delete_all
    partial = MarketData::HealthReport.for(owner:, current_market_price_service: CurrentPriceService.new)
    assert_equal :partial, partial.entries.find { |entry| entry.code == :portfolio_performance }.status
  end

  test "marks partially covered historical sources as partial" do
    owner = users(:owner)
    owner.update!(reporting_currency: "BRL")
    instrument = instruments(:voo_arcx)
    owner.trades.create!(instrument:, institution: institutions(:owner_inactive), side: :buy,
      traded_on: Date.new(2026, 9, 1), quantity: 1, unit_price: 10, fees_cents: 0, currency: "USD")
    first_date = owner.trades.where(instrument:).minimum(:traded_on)
    partial_date = TradingCalendar.weekdays_between(first_date, Date.new(2026, 9, 1)).first
    HistoricalExchangeRate.delete_all
    DailyClosingPrice.create!(instrument:, trading_date: partial_date, close_price: 1,
      currency: instrument.currency, provider: "yahoo_finance", observed_at: Time.current)
    HistoricalExchangeRate.create!(base_currency: "USD", quote_currency: "BRL", rate_date: partial_date,
      rate: 5, provider: "bcb", observed_at: Time.current, fetched_at: Time.current)
    benchmark = MarketBenchmark.create!(identifier: "PARTIALSP", name: "Partial S&P", kind: :price,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "^GSPC")
    MarketBenchmarkObservation.create!(market_benchmark: benchmark, observed_on: partial_date, value: 1,
      currency: "USD", provider: "yahoo_finance", observed_at: Time.current)

    report = MarketData::HealthReport.for(owner:, current_market_price_service: CurrentPriceService.new,
      today: Date.new(2026, 9, 2))

    assert_equal :partial, report.entries.find { |entry| entry.code == :missing_daily_close }.status
    assert_equal :partial, report.entries.find { |entry| entry.code == :missing_exchange_rate }.status
    assert_equal :partial, report.entries.find { |entry| entry.subject == benchmark }.status
  end

  test "returns no daily dates for an instrument without trades" do
    report = MarketData::HealthReport.new(owner: users(:owner), current_market_price_service: CurrentPriceService.new,
      today: Date.current)

    assert_empty report.send(:required_daily_close_dates, instruments(:petr4_bvmf))
  end

  test "returns no performance entries for an owner without trades" do
    owner = User.create!(email_address: "health-empty@example.com", password: "password", password_confirmation: "password",
      reporting_currency: "BRL")
    PortfolioPerformanceMaterialization.for(user: owner, reporting_currency: owner.reporting_currency)
    report = MarketData::HealthReport.new(owner:, current_market_price_service: CurrentPriceService.new, today: Date.current)

    assert_empty report.send(:performance_entries)
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
