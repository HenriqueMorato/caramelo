require "test_helper"

class MarketData::HealthReportTest < ActiveSupport::TestCase
  Lookup = Data.define(:status) do
    def fresh? = status == :fresh
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

  class CurrentExchangeRateService
    def initialize(status: :fresh)
      @status = status
    end

    def read(base_currency:, quote_currency:)
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

    assert_equal %i[stale_current_price missing_daily_close missing_current_exchange_rate missing_exchange_rate missing_benchmark_data], report.issues.map(&:code)
    assert_equal 5, report.warnings.size
    refute report.healthy?
  end

  test "offers recovery for a configured CDI benchmark provider" do
    benchmark = MarketBenchmark.create!(identifier: "CDI", name: "CDI", kind: :rate, currency: "BRL",
      provider: "bcb", provider_identifier: "CDI")

    report = MarketData::HealthReport.for(owner: users(:owner), current_market_price_service: CurrentPriceService.new,
      today: Date.new(2026, 9, 2))
    entry = report.entries.find { |candidate| candidate.subject == benchmark }

    assert_equal :missing, entry.status
    assert_includes entry.description, "missing observations"
    assert_predicate entry, :actionable?
  end

  test "does not report a missing range after provider scans reach today" do
    today = Date.new(2026, 9, 2)
    scan = CorporateActionImportScan.create!(
      user: users(:owner), instrument: instruments(:voo_arcx),
      source: CorporateActionImports::Providers::YAHOO_FINANCE,
      status: :succeeded, scanned_through: today, completed_at: Time.current
    )

    entry = MarketData::HealthReport::CorporateActionImports.new(
      owner: users(:owner), today:
    ).entries.find { |candidate| candidate.target.record_id == scan.instrument_id }

    assert_equal :healthy, entry.status
    assert_nil entry.missing_range

    inspector = MarketData::HealthReport::CorporateActionImports.new(owner: users(:owner), today:)
    assert_nil inspector.send(:covered_range, scan, first_trade_on: nil)
  end

  test "does not report Brazilian banking holidays as missing CDI observations" do
    benchmark = MarketBenchmark.create!(identifier: "CDI", name: "CDI", kind: :rate, currency: "BRL",
      provider: "bcb", provider_identifier: "CDI")
    from = users(:owner).trades.minimum(:traded_on)
    to = Date.new(2026, 9, 8)
    MarketData::BrazilianBankingCalendar.business_days_between(from, to).each do |date|
      benchmark.observations.create!(observed_on: date, value: "0.0005", currency: "BRL",
        provider: "bcb", observed_at: Time.current)
    end

    entry = MarketData::HealthReport::BenchmarkObservations.new(
      owner: users(:owner), today: Date.new(2026, 9, 9)
    ).entries.find { |candidate| candidate.subject == benchmark }

    assert_equal :healthy, entry.status
    refute_includes entry.description, Date.new(2026, 9, 7).iso8601
  end

  test "allows one banking day for CDI publication before making it actionable" do
    benchmark = MarketBenchmark.create!(identifier: "CDI", name: "CDI", kind: :rate, currency: "BRL",
      provider: "bcb", provider_identifier: "CDI")
    from = users(:owner).trades.minimum(:traded_on)
    MarketData::BrazilianBankingCalendar.business_days_between(from, Date.new(2026, 9, 10)).each do |date|
      benchmark.observations.create!(observed_on: date, value: "0.0005", currency: "BRL",
        provider: "bcb", observed_at: Time.current)
    end

    weekend_entry = MarketData::HealthReport::BenchmarkObservations.new(
      owner: users(:owner), today: Date.new(2026, 9, 12)
    ).entries.find { |candidate| candidate.subject == benchmark }

    assert_equal :healthy, weekend_entry.status
    assert_nil weekend_entry.missing_range

    monday_entry = MarketData::HealthReport::BenchmarkObservations.new(
      owner: users(:owner), today: Date.new(2026, 9, 14)
    ).entries.find { |candidate| candidate.subject == benchmark }

    assert_equal :partial, monday_entry.status
    assert_equal Date.new(2026, 9, 11)..Date.new(2026, 9, 11), monday_entry.missing_range
    assert_predicate monday_entry, :actionable?
  end

  test "requires no CDI observation when the entire window is a banking holiday" do
    owner = User.create!(email_address: "holiday-health@example.com", password: "password")
    owner.trades.create!(instrument: instruments(:voo_arcx), side: :buy,
      traded_on: Date.new(2026, 9, 7), quantity: 1, unit_price: 10, currency: "USD")
    benchmark = MarketBenchmark.create!(identifier: "CDI", name: "CDI", kind: :rate, currency: "BRL",
      provider: "bcb", provider_identifier: "CDI")

    entry = MarketData::HealthReport::BenchmarkObservations.new(
      owner:, today: Date.new(2026, 9, 8)
    ).entries.find { |candidate| candidate.subject == benchmark }

    assert_equal :healthy, entry.status
    assert_nil entry.missing_range
  end

  test "reports missing FX against the selected reporting currency" do
    users(:owner).update!(reporting_currency: "EUR")

    report = MarketData::HealthReport.for(current_market_price_service: CurrentPriceService.new)

    issue = report.issues.find { |item| item.code == :missing_exchange_rate }
    assert_includes issue.details, "USD/EUR"
  end

  test "reports historical FX and performance for income-only instruments" do
    owner = User.create!(email_address: "income-health@example.com", password: "password")
    instrument = instruments(:voo_arcx)
    performance_on = Date.new(2026, 9, 10)
    owner.corporate_actions.create!(
      instrument:, kind: :dividend, paid_on: performance_on + 2.days, ex_date: performance_on,
      gross_amount_cents: 1_000, withholding_tax_cents: 0, net_amount_cents: 1_000,
      currency: "USD", source: "manual"
    )
    owner.corporate_actions.create!(
      instrument: instruments(:petr4_bvmf), kind: :dividend, paid_on: performance_on,
      gross_amount_cents: 500, withholding_tax_cents: 0, net_amount_cents: 500,
      currency: "BRL", source: "manual"
    )
    PortfolioPerformanceMaterialization.for(user: owner, reporting_currency: "BRL")
    InstrumentPerformanceMaterialization.for(user: owner, instrument:, reporting_currency: "USD")
    InstrumentPerformanceMaterialization.for(user: owner, instrument:, reporting_currency: "BRL")

    report = MarketData::HealthReport.for(
      owner:, current_market_price_service: CurrentPriceService.new,
      current_exchange_rate_service: CurrentExchangeRateService.new,
      today: Date.new(2026, 9, 12)
    )

    fx_entry = report.entries.find { |entry| entry.code == :missing_exchange_rate && entry.subject == "USD" }
    portfolio_entry = report.entries.find { |entry| entry.code == :portfolio_performance }
    performance_entries = report.entries.select do |entry|
      entry.code == :instrument_performance && entry.subject == instrument
    end
    assert_equal performance_on..performance_on, fx_entry.missing_range
    assert_equal performance_on..Date.new(2026, 9, 12), portfolio_entry.missing_range
    assert_equal %w[BRL USD], performance_entries.map { |entry| entry.target.quote_currency }.sort
    expected_performance_range = performance_on..Date.new(2026, 9, 12)
    assert performance_entries.all? { |entry| entry.missing_range == expected_performance_range }
    current_market_entries = report.entries.select do |entry|
      %i[missing_current_price missing_daily_close missing_current_exchange_rate].include?(entry.code)
    end
    assert_empty current_market_entries
  end

  test "reports historical FX needed to compare a global index" do
    owner = User.create!(email_address: "benchmark-health@example.com", password: "password")
    owner.trades.create!(instrument: instruments(:petr4_bvmf), side: :buy, traded_on: Date.new(2026, 9, 1),
      quantity: 1, unit_price: 10, currency: "BRL")
    MarketBenchmark.create!(identifier: "ACWI_HEALTH", name: "Global index", kind: :total_return,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "IMID.L", return_convention: :net)

    context = MarketData::HealthReport::Context.new(owner:, today: Date.new(2026, 9, 3))
    entry = MarketData::HealthReport::HistoricalExchangeRates.new(owner:, context:).entries
      .find { |candidate| candidate.subject == "USD" }

    assert_equal :missing, entry.status
    assert_equal Date.new(2026, 9, 1)..Date.new(2026, 9, 2), entry.missing_range
  end

  test "uses the prior business day when checking benchmark FX on a weekend" do
    owner = User.create!(email_address: "benchmark-weekend-health@example.com", password: "password")
    owner.trades.create!(instrument: instruments(:petr4_bvmf), side: :buy, traded_on: Date.new(2026, 9, 1),
      quantity: 1, unit_price: 10, currency: "BRL")
    MarketBenchmark.create!(identifier: "ACWI_WEEKEND_HEALTH", name: "Global index", kind: :total_return,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "IMID.L", return_convention: :net)

    context = MarketData::HealthReport::Context.new(owner:, today: Date.new(2026, 9, 5))
    inspector = MarketData::HealthReport::HistoricalExchangeRates.new(owner:, context:)

    assert_equal Date.new(2026, 9, 4), inspector.send(:historical_end_date)
  end

  test "does not require benchmark FX when the owner has no performance start" do
    owner = User.create!(email_address: "benchmark-empty-health@example.com", password: "password")
    MarketBenchmark.create!(identifier: "ACWI_EMPTY_HEALTH", name: "Global index", kind: :total_return,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "IMID.L", return_convention: :net)
    context = MarketData::HealthReport::Context.new(owner:, today: Date.new(2026, 9, 5))
    inspector = MarketData::HealthReport::HistoricalExchangeRates.new(owner:, context:)

    assert_empty inspector.send(:benchmark_dates, "USD")
  end

  test "does not request benchmark history for an owner without activity" do
    owner = User.create!(email_address: "benchmark-no-activity@example.com", password: "password")
    benchmark = MarketBenchmark.create!(identifier: "ACWI_NO_ACTIVITY", name: "Global index", kind: :total_return,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "IMID.L", return_convention: :net)
    context = MarketData::HealthReport::Context.new(owner:, today: Date.new(2026, 9, 5))
    inspector = MarketData::HealthReport::BenchmarkObservations.new(owner:, today: context.today, context:)

    entry = inspector.entries.find { |candidate| candidate.subject == benchmark }

    assert_equal :healthy, entry.status
    assert_nil entry.missing_range
  end

  test "treats a carry-forward-complete index calendar as healthy" do
    owner = User.create!(email_address: "benchmark-holiday-health@example.com", password: "password")
    owner.trades.create!(instrument: instruments(:petr4_bvmf), side: :buy, traded_on: Date.new(2026, 9, 1),
      quantity: 1, unit_price: 10, currency: "BRL")
    benchmark = MarketBenchmark.create!(identifier: "HOLIDAY_INDEX", name: "Holiday index", kind: :price,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "^GSPC")
    [ Date.new(2026, 9, 1), Date.new(2026, 9, 7) ].each do |date|
      benchmark.observations.create!(observed_on: date, value: 1, currency: "USD", provider: "yahoo_finance",
        observed_at: Time.current)
    end

    entry = MarketData::HealthReport::BenchmarkObservations.new(owner:, today: Date.new(2026, 9, 9)).entries
      .find { |candidate| candidate.subject == benchmark }

    assert_equal :healthy, entry.status
  end

  test "starts global benchmark FX requirements at the proxy listing date" do
    owner = User.create!(email_address: "benchmark-start-health@example.com", password: "password")
    owner.trades.create!(instrument: instruments(:petr4_bvmf), side: :buy, traded_on: Date.new(2010, 1, 4),
      quantity: 1, unit_price: 10, currency: "BRL")
    benchmark = MarketBenchmark.create!(identifier: "ACWI_START_HEALTH", name: "Global index", kind: :total_return,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "IMID.L", return_convention: :net)
    context = MarketData::HealthReport::Context.new(owner:, today: Date.new(2011, 7, 28))
    inspector = MarketData::HealthReport::HistoricalExchangeRates.new(owner:, context:)

    dates = inspector.send(:benchmark_dates, benchmark.currency)

    assert_equal Date.new(2011, 7, 26), dates.min
  end

  test "includes rate benchmark currencies in historical FX health" do
    owner = User.create!(email_address: "rate-benchmark-health@example.com", password: "password",
      reporting_currency: "USD")
    owner.trades.create!(instrument: instruments(:voo_arcx), side: :buy, traded_on: Date.new(2026, 9, 1),
      quantity: 1, unit_price: 10, currency: "USD")
    MarketBenchmark.create!(identifier: "CDI_HEALTH", name: "CDI", kind: :rate, currency: "BRL",
      provider: "bcb", provider_identifier: "CDI")
    context = MarketData::HealthReport::Context.new(owner:, today: Date.new(2026, 9, 5))

    entries = MarketData::HealthReport::HistoricalExchangeRates.new(owner:, context:).entries

    assert_equal "BRL", entries.find { |entry| entry.subject == "BRL" }.subject
  end

  test "skips benchmark FX sources that ended before the owner performance start" do
    owner = User.create!(email_address: "benchmark-ended-health@example.com", password: "password")
    owner.trades.create!(instrument: instruments(:petr4_bvmf), side: :buy, traded_on: Date.new(2026, 9, 4),
      quantity: 1, unit_price: 10, currency: "BRL")
    benchmark = MarketBenchmark.create!(identifier: "ACWI_ENDED_HEALTH", name: "Global index", kind: :total_return,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "IMID.L", return_convention: :net)
    context = MarketData::HealthReport::Context.new(owner:, today: Date.new(2026, 9, 5))
    inspector = MarketData::HealthReport::HistoricalExchangeRates.new(owner:, context:)
    importer = Object.new
    importer.define_singleton_method(:available_through_for) { |**| Date.new(2026, 9, 3) }
    importer.define_singleton_method(:expected_dates_for) { |**| flunk "ended benchmark should not request dates" }
    inspector.define_singleton_method(:benchmark_importer) { importer }

    assert_empty inspector.send(:benchmark_dates, benchmark.currency)
  end

  test "requires historical FX for open-position valuation dates" do
    owner = users(:owner)
    HistoricalExchangeRate.delete_all
    from = owner.trades.minimum(:traded_on)
    TradingCalendar.weekdays_between(from, Date.new(2026, 9, 4)).each do |date|
      HistoricalExchangeRate.create!(base_currency: "USD", quote_currency: "BRL", rate_date: date,
        rate: 5, provider: "yahoo_finance_fx", observed_at: Time.current, fetched_at: Time.current)
    end

    entry = MarketData::HealthReport::HistoricalExchangeRates.new(
      owner:, context: MarketData::HealthReport::Context.new(owner:, today: Date.new(2026, 9, 12))
    ).entries.find { |candidate| candidate.subject == "USD" }

    assert_equal :partial, entry.status
    assert_equal Date.new(2026, 9, 12)..Date.new(2026, 9, 12), entry.missing_range
    assert_predicate entry, :actionable?
  end

  test "requires valuation FX only while a foreign position is open" do
    owner = User.create!(email_address: "closed-fx-health@example.com", password: "password")
    instrument = instruments(:voo_arcx)
    buy_date = Date.new(2026, 9, 1)
    owner.trades.create!(instrument:, side: :buy, traded_on: buy_date, quantity: 1, unit_price: 10, currency: "USD")
    owner.trades.create!(instrument:, side: :sell, traded_on: buy_date + 1.day, quantity: 1, unit_price: 11, currency: "USD")
    inspector = MarketData::HealthReport::HistoricalExchangeRates.new(
      owner:, context: MarketData::HealthReport::Context.new(owner:, today: buy_date + 2.days)
    )

    assert_equal [ buy_date ], inspector.send(:open_position_dates, instrument)
  end

  test "stops requiring valuation FX after a reverse split and adjusted sale close the position" do
    owner = User.create!(email_address: "reverse-split-fx-health@example.com", password: "password")
    instrument = instruments(:voo_arcx)
    buy_date = Date.new(2026, 9, 1)
    owner.trades.create!(instrument:, side: :buy, traded_on: buy_date, quantity: 2, unit_price: 10, currency: "USD")
    owner.corporate_actions.create!(
      instrument:, kind: :reverse_split, effective_on: buy_date + 1.day,
      ratio_numerator: 1, ratio_denominator: 2, source: "manual"
    )
    owner.trades.create!(
      instrument:, side: :sell, traded_on: buy_date + 2.days, quantity: 1, unit_price: 21, currency: "USD"
    )
    inspector = MarketData::HealthReport::HistoricalExchangeRates.new(
      owner:, context: MarketData::HealthReport::Context.new(owner:, today: buy_date + 3.days)
    )

    assert_equal [ buy_date, buy_date + 1.day ], inspector.send(:open_position_dates, instrument)
  end

  test "stops requiring valuation FX after cash in lieu closes the position" do
    owner = User.create!(email_address: "cash-in-lieu-fx-health@example.com", password: "password")
    instrument = instruments(:voo_arcx)
    buy_date = Date.new(2026, 9, 1)
    owner.trades.create!(instrument:, side: :buy, traded_on: buy_date, quantity: 1, unit_price: 10, currency: "USD")
    owner.corporate_actions.create!(
      instrument:, kind: :stock_split, effective_on: buy_date + 1.day,
      ratio_numerator: 2, ratio_denominator: 1, cash_in_lieu_quantity: 2,
      cash_in_lieu_amount_cents: 2_000, currency: "USD", source: "manual"
    )
    inspector = MarketData::HealthReport::HistoricalExchangeRates.new(
      owner:, context: MarketData::HealthReport::Context.new(owner:, today: buy_date + 2.days)
    )

    assert_equal [ buy_date ], inspector.send(:open_position_dates, instrument)
  end

  test "retains safe trade dates when an invalid quantity action cannot replay" do
    owner = User.create!(email_address: "invalid-action-fx-health@example.com", password: "password")
    instrument = instruments(:voo_arcx)
    buy_date = Date.new(2026, 9, 1)
    owner.trades.create!(instrument:, side: :buy, traded_on: buy_date, quantity: 1, unit_price: 10, currency: "USD")
    owner.trades.create!(
      instrument:, side: :sell, traded_on: buy_date + 2.days, quantity: 1, unit_price: 11, currency: "USD"
    )
    owner.corporate_actions.create!(
      instrument:, kind: :stock_split, effective_on: buy_date + 1.day,
      ratio_numerator: 2, ratio_denominator: 1, cash_in_lieu_quantity: 3,
      cash_in_lieu_amount_cents: 1_000, currency: "USD", source: "manual"
    )
    inspector = MarketData::HealthReport::HistoricalExchangeRates.new(
      owner:, context: MarketData::HealthReport::Context.new(owner:, today: buy_date + 3.days)
    )

    assert_equal [ buy_date, buy_date + 1.day ], inspector.send(:open_position_dates, instrument)
  end

  test "handles instruments without trades and missing cash-in-lieu proceeds" do
    owner = User.create!(email_address: "invalid-cash-fx-health@example.com", password: "password")
    empty_instrument = Instrument.create!(
      ticker: "NOFX", exchange: "XNAS", name: "No FX trades", currency: "USD"
    )
    instrument = instruments(:voo_arcx)
    buy_date = Date.new(2026, 9, 1)
    owner.trades.create!(instrument:, side: :buy, traded_on: buy_date, quantity: 1, unit_price: 10, currency: "USD")
    action = owner.corporate_actions.create!(
      instrument:, kind: :stock_split, effective_on: buy_date + 1.day,
      ratio_numerator: 2, ratio_denominator: 1, cash_in_lieu_quantity: 1,
      cash_in_lieu_amount_cents: 1_000, currency: "USD", source: "manual"
    )
    context = MarketData::HealthReport::Context.new(owner:, today: buy_date + 2.days)
    context.corporate_actions.find { |candidate| candidate.id == action.id }.cash_in_lieu_amount_cents = nil
    inspector = MarketData::HealthReport::HistoricalExchangeRates.new(owner:, context:)

    assert_empty inspector.send(:open_position_dates, empty_instrument)
    assert_equal (buy_date..buy_date + 2.days).to_a, inspector.send(:open_position_dates, instrument)
  end

  test "reports stale current FX for an open foreign position" do
    report = MarketData::HealthReport.for(
      current_market_price_service: CurrentPriceService.new,
      current_exchange_rate_service: CurrentExchangeRateService.new(status: :stale)
    )

    entry = report.entries.find { |candidate| candidate.code == :missing_current_exchange_rate }
    assert_equal :stale, entry.status
    assert_includes entry.description, "Current USD/BRL exchange rate is stale"
  end

  test "treats the reporting currency as having no FX gap" do
    owner = users(:owner)
    owner.trades.create!(instrument: instruments(:petr4_bvmf), institution: institutions(:owner_xp),
      side: :buy, traded_on: Date.new(2026, 8, 28), quantity: 1, unit_price: 10, currency: "BRL")

    report = MarketData::HealthReport.for(
      owner:, current_market_price_service: CurrentPriceService.new,
      current_exchange_rate_service: CurrentExchangeRateService.new
    )

    refute report.entries.any? { |entry| entry.subject == "BRL" && entry.code == :missing_exchange_rate }
  end

  test "carries Friday FX across a weekend valuation" do
    owner = users(:owner)
    instrument = Instrument.create!(ticker: "EUNL", exchange: "XETR", name: "European ETF", currency: "EUR")
    saturday = Date.new(2026, 8, 15)
    owner.trades.create!(instrument:, institution: institutions(:owner_xp), side: :buy,
      traded_on: saturday, quantity: 1, unit_price: 10, currency: "EUR")
    HistoricalExchangeRate.create!(base_currency: "EUR", quote_currency: "BRL", rate_date: saturday - 1.day,
      rate: 6, provider: "yahoo_finance", observed_at: Time.current, fetched_at: Time.current)

    report = MarketData::HealthReport.for(owner:, current_market_price_service: CurrentPriceService.new,
      current_exchange_rate_service: CurrentExchangeRateService.new, today: saturday)

    entry = report.entries.find { |candidate| candidate.subject == "EUR" && candidate.code == :exchange_rate }
    assert_equal :healthy, entry.status
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

  test "formats an instrument subject label" do
    report = MarketData::HealthReport.new(owner: users(:owner), current_market_price_service: CurrentPriceService.new,
      current_exchange_rate_service: CurrentExchangeRateService.new, today: Date.current)

    label = report.instance_exec(instruments(:voo_arcx)) { |instrument| subject_label(instrument) }

    assert_equal "VOO · Vanguard S&P 500 ETF", label
  end

  test "formats identifier and plain subjects when no ticker is available" do
    report = MarketData::HealthReport.new(owner: users(:owner), current_market_price_service: CurrentPriceService.new,
      current_exchange_rate_service: CurrentExchangeRateService.new, today: Date.current)
    identifier_subject = Data.define(:name, :identifier).new("S&P 500", "SP500")

    assert_equal "S&P 500 (SP500)", report.instance_exec(identifier_subject) { |subject| subject_label(subject) }
    assert_equal "Portfolio", report.instance_exec("Portfolio") { |subject| subject_label(subject) }
  end

  test "exposes the context reporting currency" do
    context = MarketData::HealthReport::Context.new(owner: users(:owner), today: Date.current)

    assert_equal users(:owner).reporting_currency, context.reporting_currency
  end

  test "handles a weekend benchmark health window" do
    benchmark = MarketBenchmark.create!(identifier: "WEEKENDSP", name: "Weekend S&P", kind: :price,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "^GSPC")
    inspector = MarketData::HealthReport::BenchmarkObservations.new(
      owner: users(:owner), today: Date.new(2026, 9, 6)
    )

    entry = inspector.entries.find { |candidate| candidate.subject == benchmark }

    assert_equal :missing, entry.status
    assert_includes entry.description, Date.new(2026, 9, 4).iso8601
  end

  test "labels a missing latest benchmark session as delayed" do
    owner = User.create!(email_address: "delayed-benchmark-health@example.com", password: "password")
    owner.trades.create!(instrument: instruments(:petr4_bvmf), side: :buy, traded_on: Date.new(2026, 9, 1),
      quantity: 1, unit_price: 10, currency: "BRL")
    benchmark = MarketBenchmark.create!(identifier: "DELAYEDSP", name: "Delayed S&P", kind: :price,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "^GSPC")
    [ Date.new(2026, 9, 1), Date.new(2026, 9, 10), Date.new(2026, 9, 18) ].each do |date|
      benchmark.observations.create!(observed_on: date, value: 1, currency: "USD", provider: "yahoo_finance",
        observed_at: Time.current)
    end

    entry = MarketData::HealthReport::BenchmarkObservations.new(owner:, today: Date.new(2026, 9, 22)).entries
      .find { |candidate| candidate.subject == benchmark }

    assert_equal :delayed, entry.status
    assert_includes entry.description, "delayed"
    assert_predicate entry, :actionable?
  end

  test "labels an old missing latest benchmark session as stale" do
    owner = User.create!(email_address: "stale-benchmark-health@example.com", password: "password")
    owner.trades.create!(instrument: instruments(:petr4_bvmf), side: :buy, traded_on: Date.new(2026, 9, 1),
      quantity: 1, unit_price: 10, currency: "BRL")
    benchmark = MarketBenchmark.create!(identifier: "STALESP", name: "Stale S&P", kind: :price,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "^GSPC")
    benchmark.observations.create!(observed_on: Date.new(2026, 9, 1), value: 1, currency: "USD",
      provider: "yahoo_finance", observed_at: Time.current)

    entry = MarketData::HealthReport::BenchmarkObservations.new(owner:, today: Date.new(2026, 9, 10)).entries
      .find { |candidate| candidate.subject == benchmark }

    assert_equal :stale, entry.status
    assert_includes entry.description, "stale"
    assert_predicate entry, :actionable?
  end

  test "formats a single benchmark date without a range separator" do
    inspector = MarketData::HealthReport::BenchmarkObservations.new(owner: users(:owner), today: Date.current)

    assert_equal Date.current.iso8601, inspector.send(:format_ranges, [ Date.current..Date.current ])
  end

  test "builds current FX entries with optional coverage ranges" do
    inspector = MarketData::HealthReport::CurrentExchangeRates.new(
      context: MarketData::HealthReport::Context.new(owner: users(:owner), today: Date.current),
      service: CurrentExchangeRateService.new
    )
    coverage = MarketData::HealthReport::CoverageCalculator.for(required_dates: [], observations: [])

    entry = inspector.send(
      :build, code: :current_exchange_rate, target: MarketData::Target.new(kind: :current_exchange_rate),
      subject: "USD", status: :healthy, severity: nil, description: "available", actions: [], coverage:
    )

    assert_nil entry.covered_range
    assert_nil entry.missing_range
  end

  test "covers historical FX inspector fallbacks and range formatting" do
    owner = users(:owner)
    inspector = MarketData::HealthReport::HistoricalExchangeRates.new(owner:)

    assert_empty inspector.send(:observations_for, "BRL", [])
    assert inspector.entries.any?
    dates = inspector.send(:historical_rate_dates, "USD")
    assert_equal (owner.trades.minimum(:traded_on)..Date.current).to_a, dates.sort
    assert_equal "2026-09-01–2026-09-03", inspector.send(
      :format_ranges, [ Date.new(2026, 9, 1)..Date.new(2026, 9, 3) ]
    )
  end

  test "reports healthy when all required records exist" do
    instrument = instruments(:voo_arcx)
    TradingCalendar.weekdays_between(Date.new(2026, 8, 12), Date.new(2026, 9, 1)).each do |date|
      DailyClosingPrice.create!(instrument:, trading_date: date, close_price: 620,
        currency: instrument.currency, provider: "yahoo_finance", observed_at: Time.current)
    end
    TradingCalendar.weekdays_between(Date.new(2026, 8, 12), Date.new(2026, 9, 2)).each do |date|
      HistoricalExchangeRate.create!(base_currency: "USD", quote_currency: "BRL", rate_date: date,
        rate: 5, provider: "bcb", observed_at: Time.current, fetched_at: Time.current)
    end
    benchmark = MarketBenchmark.create!(identifier: "HEALTHSP", name: "Health S&P", kind: :price, currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^GSPC")
    TradingCalendar.weekdays_between(Date.new(2026, 8, 12), Date.new(2026, 9, 1)).each do |date|
      MarketBenchmarkObservation.create!(market_benchmark: benchmark, observed_on: date, value: 1,
        currency: "USD", provider: "yahoo_finance", observed_at: Time.current)
    end

    report = MarketData::HealthReport.for(
      owner: users(:owner), current_market_price_service: CurrentPriceService.new,
      current_exchange_rate_service: CurrentExchangeRateService.new,
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
    assert_equal Date.new(2026, 9, 2)..Date.new(2026, 9, 7), coverage.missing_range
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

  test "does not carry a rate observation across a missing accrual date" do
    coverage = MarketData::HealthReport::CoverageCalculator.for(
      required_dates: (Date.new(2026, 9, 1)..Date.new(2026, 9, 2)).to_a,
      observations: [ DailyClosingPrice.new(trading_date: Date.new(2026, 9, 1)) ],
      carry_forward: false
    )

    assert_predicate coverage, :partial?
    assert_equal [ Date.new(2026, 9, 2)..Date.new(2026, 9, 2) ], coverage.missing_ranges
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

  test "builds performance coverage without a shared context" do
    owner = users(:owner)
    PortfolioPerformanceMaterialization.for(user: owner, reporting_currency: owner.reporting_currency)

    entries = MarketData::HealthReport::PortfolioPerformance.new(owner:, today: Date.current).entries

    assert_equal 1, entries.size
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

  test "does not count missing portfolio observations as covered" do
    owner = users(:owner)
    first_date = owner.trades.minimum(:traded_on)
    materialization = PortfolioPerformanceMaterialization.for(user: owner, reporting_currency: owner.reporting_currency)
    PortfolioPerformanceObservation.create!(
      user: owner, reporting_currency: owner.reporting_currency, observed_on: first_date,
      generated_at: Time.current, status: :missing, source_generation: materialization.source_generation
    )

    entry = MarketData::HealthReport::PortfolioPerformance.new(owner:, today: first_date).entries.sole

    assert_equal :missing, entry.status
    assert_equal first_date..first_date, entry.missing_range
  end

  test "reports pending and missing instrument performance currency views" do
    owner = users(:owner)
    instrument = instruments(:voo_arcx)
    first_date = owner.trades.where(instrument:).minimum(:traded_on)
    pending = InstrumentPerformanceMaterialization.for(user: owner, instrument:, reporting_currency: "USD")
    pending.request!(from: first_date, to: first_date)
    InstrumentPerformanceMaterialization.for(user: owner, instrument:, reporting_currency: "BRL")

    entries = MarketData::HealthReport::InstrumentPerformance.new(
      owner:, today: first_date, context: nil
    ).entries.index_by { |entry| entry.target.quote_currency }

    assert_equal :updating, entries.fetch("USD").status
    assert_empty entries.fetch("USD").actions
    assert_equal :missing, entries.fetch("BRL").status
    assert_equal [ :retry ], entries.fetch("BRL").actions
  end

  test "reports automatic corporate-action scan progress and failures" do
    owner = users(:owner)
    instrument = instruments(:voo_arcx)
    scan = CorporateActionImportScan.for(user: owner, instrument:)
    scan.update!(status: :queued, requested_from: Date.current - 2.days, requested_to: Date.current)

    queued = MarketData::HealthReport::CorporateActionImports.new(owner:, today: Date.current).entries.sole
    assert_equal :updating, queued.status
    assert_empty queued.actions

    scan.update!(status: :failed, requested_from: Date.current - 2.days, requested_to: Date.current,
      failure_message: "provider timeout")
    failed = MarketData::HealthReport::CorporateActionImports.new(owner:, today: Date.current).entries.sole
    assert_equal :failed, failed.status
    assert_equal :error, failed.severity
    assert_predicate failed, :actionable?
    assert_includes failed.description, "provider timeout"
    assert_equal :corporate_action_imports, failed.target.kind
  end

  test "reports a completed scan as healthy through its watermark" do
    owner = users(:owner)
    instrument = instruments(:voo_arcx)
    CorporateActionImportScan.create!(
      user: owner, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE,
      status: :succeeded, scanned_through: Date.current, completed_at: Time.current
    )

    entry = MarketData::HealthReport.for(
      owner:, current_market_price_service: CurrentPriceService.new, today: Date.current
    ).entries.find { |candidate| candidate.code == :corporate_action_imports }

    assert_equal :healthy, entry.status
    assert_empty entry.actions
  end

  test "reports an abandoned active scan as failed and retryable" do
    owner = users(:owner)
    instrument = instruments(:voo_arcx)
    scan = CorporateActionImportScan.for(user: owner, instrument:)
    scan.update!(
      status: :running, run_id: SecureRandom.uuid, requested_from: Date.current - 2.days,
      requested_to: Date.current, started_at: 2.days.ago
    )

    entry = MarketData::HealthReport::CorporateActionImports.new(owner:, today: Date.current).entries.sole

    assert_equal :failed, entry.status
    assert_equal :error, entry.severity
    assert_equal [ :retry ], entry.actions
    assert_includes entry.description, "lease expired"
  end

  test "does not report a scan after the owner deletes all trades for its instrument" do
    owner = User.create!(email_address: "scan-health-empty@example.com", password: "password")
    instrument = instruments(:voo_arcx)
    CorporateActionImportScan.create!(user: owner, instrument:, status: :failed, failure_message: "provider down")

    assert_empty MarketData::HealthReport::CorporateActionImports.new(owner:, today: Date.current).entries
  end

  test "does not report a scan for an instrument whose first trade is still in the future" do
    owner = User.create!(email_address: "future-scan-health@example.com", password: "password")
    instrument = instruments(:voo_arcx)
    owner.trades.create!(instrument:, side: :buy, traded_on: Date.current + 1.day, quantity: 1, unit_price: 10, currency: "USD")
    CorporateActionImportScan.create!(user: owner, instrument:, status: :queued,
      requested_from: Date.current, requested_to: Date.current)

    entries = MarketData::HealthReport::CorporateActionImports.new(owner:, today: Date.current).entries

    assert_empty entries
  end

  test "maps a corporate-action issue to its health target" do
    issue = MarketData::HealthReport::Issue.new(
      code: :corporate_action_imports, severity: :warning, subject: instruments(:voo_arcx), details: "stale"
    )

    entry = MarketData::HealthReport::Result.new(checked_at: Time.current, issues: [ issue ]).entries.sole

    assert_equal :corporate_action_imports, entry.target.kind
    assert_equal instruments(:voo_arcx).id, entry.target.record_id
  end

  test "reports the missing range after an automatic scan watermark" do
    owner = users(:owner)
    instrument = instruments(:voo_arcx)
    scanned_through = Date.current - 2.days
    CorporateActionImportScan.create!(
      user: owner, instrument:, source: CorporateActionImports::Providers::YAHOO_FINANCE,
      status: :succeeded, scanned_through:, completed_at: Time.current
    )

    entry = MarketData::HealthReport::CorporateActionImports.new(owner:, today: Date.current).entries.sole

    assert_equal :stale, entry.status
    assert_equal (scanned_through + 1.day)..Date.current, entry.missing_range
  end

  test "ignores an active instrument marker when no durable work remains" do
    owner = users(:owner)
    instrument = instruments(:voo_arcx)
    first_date = owner.trades.where(instrument:).minimum(:traded_on)
    InstrumentPerformanceMaterialization.for(user: owner, instrument:, reporting_currency: "USD")
    token = Performance::SeriesRefresh.acquire(user: owner, instrument:, reporting_currency: "USD")
    Performance::SeriesRefresh.queued(
      user: owner, instrument:, reporting_currency: "USD", from: first_date, to: first_date, token:
    )

    entry = MarketData::HealthReport::InstrumentPerformance.new(owner:, today: first_date).entries.find do |candidate|
      candidate.target.quote_currency == "USD"
    end

    assert_equal :missing, entry.status
  ensure
    Performance::SeriesRefresh.release(
      user: owner, instrument:, reporting_currency: "USD", token:
    ) if token
  end

  test "reports stale, partial, and healthy instrument performance" do
    owner = users(:owner)
    instrument = instruments(:voo_arcx)
    first_date = owner.trades.where(instrument:).minimum(:traded_on)
    final_date = first_date + 2.days
    materialization = InstrumentPerformanceMaterialization.for(user: owner, instrument:, reporting_currency: "USD")
    create_instrument_performance_observation(
      owner:, instrument:, materialization:, observed_on: first_date, stale_at: Time.current
    )
    inspector = MarketData::HealthReport::InstrumentPerformance.new(owner:, today: final_date)
    assert_equal :stale, inspector.entries.find { |entry| entry.target.quote_currency == "USD" }.status

    owner.instrument_performance_observations.update_all(stale_at: nil)
    assert_equal :partial, inspector.entries.find { |entry| entry.target.quote_currency == "USD" }.status

    (first_date + 1.day..final_date).each do |date|
      create_instrument_performance_observation(owner:, instrument:, materialization:, observed_on: date)
    end
    assert_equal :healthy, inspector.entries.find { |entry| entry.target.quote_currency == "USD" }.status
  end

  test "does not count missing instrument observations as covered" do
    owner = users(:owner)
    instrument = instruments(:voo_arcx)
    first_date = owner.trades.where(instrument:).minimum(:traded_on)
    materialization = InstrumentPerformanceMaterialization.for(user: owner, instrument:, reporting_currency: "USD")
    InstrumentPerformanceObservation.create!(
      user: owner, instrument:, reporting_currency: "USD", observed_on: first_date,
      status: :missing, source_generation: materialization.source_generation, generated_at: Time.current
    )

    entry = MarketData::HealthReport::InstrumentPerformance.new(owner:, today: first_date).entries.find do |candidate|
      candidate.target.quote_currency == "USD"
    end

    assert_equal :missing, entry.status
    assert_equal first_date..first_date, entry.missing_range
  end

  test "reports a failed instrument performance rebuild" do
    owner = users(:owner)
    instrument = instruments(:voo_arcx)
    first_date = owner.trades.where(instrument:).minimum(:traded_on)
    InstrumentPerformanceMaterialization.for(
      user: owner, instrument:, reporting_currency: "USD"
    ).request!(from: first_date, to: first_date)
    token = Performance::SeriesRefresh.acquire(user: owner, instrument:, reporting_currency: "USD")
    Performance::SeriesRefresh.failed(
      user: owner, instrument:, reporting_currency: "USD", from: first_date, to: first_date,
      token:, error: RuntimeError.new("calculation failed")
    )
    Performance::SeriesRefresh.release(user: owner, instrument:, reporting_currency: "USD", token:)

    entry = MarketData::HealthReport::InstrumentPerformance.new(owner:, today: first_date).entries.find do |candidate|
      candidate.target.quote_currency == "USD"
    end

    assert_equal :failed, entry.status
    assert_equal :error, entry.severity
    assert_includes entry.description, "failed to rebuild"
  end

  test "includes an existing additional instrument performance currency view" do
    owner = users(:owner)
    instrument = instruments(:voo_arcx)
    InstrumentPerformanceMaterialization.for(user: owner, instrument:, reporting_currency: "EUR")

    currencies = MarketData::HealthReport::InstrumentPerformance.new(owner:, today: Date.current)
      .entries.map { |entry| entry.target.quote_currency }

    assert_includes currencies, "EUR"
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
    MarketBenchmarkObservation.create!(market_benchmark: benchmark, observed_on: Date.new(2026, 9, 1), value: 1,
      currency: "USD", provider: "yahoo_finance", observed_at: Time.current)

    report = MarketData::HealthReport.for(owner:, current_market_price_service: CurrentPriceService.new,
      today: Date.new(2026, 9, 2))

    assert_equal :partial, report.entries.find { |entry| entry.code == :missing_daily_close }.status
    assert_equal :partial, report.entries.find { |entry| entry.code == :missing_exchange_rate }.status
    assert_equal :partial, report.entries.find { |entry| entry.subject == benchmark }.status
  end

  test "returns no daily dates for an instrument without trades" do
    report = MarketData::HealthReport.new(owner: users(:owner), current_market_price_service: CurrentPriceService.new,
      current_exchange_rate_service: CurrentExchangeRateService.new, today: Date.current)

    dates = MarketData::HealthReport::DailyClosingPrices.new(
      owner: users(:owner), instruments: [], today: Date.current
    ).dates_for(instruments(:petr4_bvmf))
    assert_empty dates
  end

  test "daily-close inspector skips queries without required dates" do
    inspector = MarketData::HealthReport::DailyClosingPrices.new(
      owner: users(:owner), instruments: [ instruments(:petr4_bvmf) ], today: Date.current
    )

    assert_predicate inspector.entries.first, :healthy?
  end

  test "daily-close inspector uses the previous business day on weekends" do
    inspector = MarketData::HealthReport::DailyClosingPrices.new(
      owner: users(:owner), instruments: [ instruments(:voo_arcx) ], today: Date.new(2026, 9, 6)
    )

    assert_equal :missing, inspector.entries.first.status
  end

  test "daily-close inspector reports a complete range" do
    owner = users(:owner)
    instrument = instruments(:voo_arcx)
    from = owner.trades.where(instrument:).minimum(:traded_on)
    to = Date.new(2026, 9, 4)
    TradingCalendar.weekdays_between(from, to).each do |date|
      DailyClosingPrice.create!(instrument:, trading_date: date, close_price: 100,
        currency: instrument.currency, provider: "yahoo_finance", observed_at: Time.current)
    end

    inspector = MarketData::HealthReport::DailyClosingPrices.new(owner:, instruments: [ instrument ], today: Date.new(2026, 9, 6))

    assert_equal :healthy, inspector.entries.first.status
  end

  test "returns no performance entries for an owner without trades" do
    owner = User.create!(email_address: "health-empty@example.com", password: "password", password_confirmation: "password",
      reporting_currency: "BRL")
    PortfolioPerformanceMaterialization.for(user: owner, reporting_currency: owner.reporting_currency)
    report = MarketData::HealthReport.new(owner:, current_market_price_service: CurrentPriceService.new, today: Date.current)

    entries = report.instance_exec { performance_entries }
    assert_empty entries
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
    refute_predicate entry, :resettable?
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

  def create_instrument_performance_observation(owner:, instrument:, materialization:, observed_on:, stale_at: nil)
    InstrumentPerformanceObservation.create!(
      user: owner, instrument:, reporting_currency: materialization.reporting_currency, observed_on:,
      status: :available, source_generation: materialization.source_generation, generated_at: Time.current,
      stale_at:, market_value_amount: "100", cost_basis_amount: "90", realized_gain_amount: "1",
      unrealized_gain_amount: "9", net_cash_flow_amount: "-90",
      investment_income_amount: "0", invested_amount: "90"
    )
  end

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

  test "gives each entry a stable DOM identifier" do
    issue = MarketData::HealthReport::Issue.new(
      code: :missing_current_price, severity: :error, subject: instruments(:voo_arcx), details: "missing"
    )

    entry = MarketData::HealthReport::Result.new(checked_at: Time.current, issues: [ issue ]).entries.first

    assert_equal "health-entry-current_market_price-#{instruments(:voo_arcx).id}", entry.dom_id
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

  test "applies queued failed interrupted and completed refresh states to every target type" do
    target = MarketData::Target.new(
      kind: :daily_closing_prices, record_id: instruments(:voo_arcx).id, provider: "yahoo_finance"
    )
    entry = health_entry(target:, status: :missing)
    inspector = MarketData::HealthReport.allocate

    RefreshStatus::State.write(scope: target.scope, status: "queued", total_count: 1)
    updating = inspector.send(:apply_refresh_state, entry)
    assert_equal :updating, updating.status
    assert_empty updating.actions

    RefreshStatus::State.write(
      scope: target.scope, status: "failed", finished_at: Time.current, error_message: "provider failed"
    )
    failed = inspector.send(:apply_refresh_state, entry)
    assert_equal :failed, failed.status
    assert_equal "provider failed", failed.description

    travel_to 11.minutes.ago do
      RefreshStatus::State.write(scope: target.scope, status: "running", started_at: Time.current)
    end
    assert_equal :interrupted, inspector.send(:apply_refresh_state, entry).status

    RefreshStatus::State.write(scope: target.scope, status: "succeeded", finished_at: Time.current)
    assert_equal entry, inspector.send(:apply_refresh_state, entry)
  end

  test "does not let an old failure make healthy source data look failed" do
    target = MarketData::Target.new(
      kind: :daily_closing_prices, record_id: instruments(:voo_arcx).id, provider: "yahoo_finance"
    )
    entry = health_entry(target:, status: :healthy)
    RefreshStatus::State.write(
      scope: target.scope, status: "failed", finished_at: Time.current, error_message: "old failure"
    )

    assert_equal entry, MarketData::HealthReport.allocate.send(:apply_refresh_state, entry)
  end

  test "offers replacement only for unhealthy supported targets" do
    source = health_entry(
      target: MarketData::Target.new(
        kind: :daily_closing_prices, record_id: instruments(:voo_arcx).id, provider: "yahoo_finance"
      ),
      status: :partial
    )
    derived = health_entry(
      target: MarketData::Target.new(kind: :portfolio_performance, quote_currency: "BRL"), status: :failed
    )

    assert_predicate source, :resettable?
    assert_predicate derived, :resettable?
    refute_predicate source.with(status: :healthy), :resettable?
    refute_predicate source.with(status: :updating), :resettable?
    refute_predicate source.with(status: :unsupported), :resettable?
    refute_predicate source.with(target: source.target.with(provider: nil)), :resettable?
  end

  private

  def health_entry(target:, status:)
    MarketData::HealthReport::Entry.new(
      code: :test, target:, subject: "Source", status:,
      severity: status == :healthy ? nil : :warning, label: "Source", description: "Source status",
      observed_on: nil, fetched_at: nil, covered_range: nil, missing_range: nil,
      actions: status == :healthy ? [] : [ :retry ]
    )
  end
end
