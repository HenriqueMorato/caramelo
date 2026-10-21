require "test_helper"

class BackfillHistoricalMarketDataJobTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    @instrument = instruments(:voo_arcx)
    @backfill = HistoricalDataBackfill.create!(instrument: @instrument, currency: "USD", from_date: Date.new(2026, 1, 1))
    @daily_imports = []
    @exchange_rate_imports = []
    @waits = []
  end

  test "imports price and FX history in bounded batches through the shared throttle" do
    travel_to Date.new(2026, 7, 10) do
      job = build_job

      job.perform(@backfill)
    end

    assert_equal [ [ Date.new(2026, 1, 1), Date.new(2026, 3, 31) ], [ Date.new(2026, 4, 1), Date.new(2026, 6, 29) ], [ Date.new(2026, 6, 30), Date.new(2026, 7, 10) ] ],
      @daily_imports.map { |call| [ call[:from], call[:to] ] }
    assert_equal @daily_imports.map { |call| [ call[:from], call[:to] ] }, @exchange_rate_imports.map { |call| [ call[:from], call[:to] ] }
    assert_equal 6, @waits.length
    assert_equal [ @instrument, nil, @instrument, nil, @instrument, nil ], @waits
    assert @daily_imports.all? { |call| call[:fence].is_a?(MarketData::PublicationFence) }
    assert @exchange_rate_imports.all? { |call| call[:fence].is_a?(MarketData::PublicationFence) }
    assert_equal 1, @daily_imports.map { |call| call.fetch(:generation) }.uniq.size
    assert_equal 1, @exchange_rate_imports.map { |call| call.fetch(:generation) }.uniq.size
    assert_not HistoricalDataBackfill.exists?(@backfill.id)
  end

  test "builds the default importers and shared Yahoo throttle" do
    job = BackfillHistoricalMarketDataJob.new

    assert_instance_of DailyClosingPrice::Importer, job.send(:daily_closing_price_importer)
    assert_instance_of HistoricalExchangeRate::Importer, job.send(:historical_exchange_rate_importer)
    assert_instance_of MarketData::YahooFinance::RequestThrottle, job.send(:request_throttle)
  end

  test "keeps one reporting currency throughout a running backfill" do
    users(:owner).update!(reporting_currency: "EUR")
    job = build_job
    @daily_importer.define_singleton_method(:call) do |**|
      User.owner.update!(reporting_currency: "USD")
    end

    travel_to(Date.new(2026, 7, 10)) { job.perform(@backfill) }

    assert_equal 3, @exchange_rate_imports.size
    assert_equal [ "EUR" ], @exchange_rate_imports.map { |call| call.fetch(:quote_currency) }.uniq
  end

  test "skips FX imports when the trade currency is the reporting currency" do
    @backfill.update!(instrument: instruments(:petr4_bvmf), currency: "BRL")

    travel_to Date.new(2026, 1, 1) do
      assert_equal Date.new(2026, 1, 1), Date.current
      build_job.perform(@backfill)
    end

    assert_equal 1, @daily_imports.size
    assert_empty @exchange_rate_imports
    assert_equal [ instruments(:petr4_bvmf) ], @waits
  end

  test "schedules another run when a request changes while importing" do
    job = build_job
    backfill = @backfill
    daily_imports = @daily_imports
    @daily_importer.define_singleton_method(:call) do |**arguments|
      backfill.update!(from_date: Date.new(2025, 12, 1), generation: backfill.generation + 1)
      daily_imports << arguments
    end

    travel_to Date.new(2026, 1, 1) do
      assert_equal Date.new(2026, 1, 1), Date.current
      job.perform(@backfill)
    end

    assert_enqueued_with(job: BackfillHistoricalMarketDataJob, args: [ @backfill ])
    assert HistoricalDataBackfill.exists?(@backfill.id)
  end

  test "rebuilds performance for an income owner even without a trade" do
    income_owner = users(:two)
    CorporateAction.create!(
      user: income_owner, instrument: @instrument, kind: :dividend, status: :confirmed,
      paid_on: Date.new(2026, 1, 1),
      gross_amount_cents: 100, withholding_tax_cents: 0, net_amount_cents: 100,
      currency: "USD", source: "manual"
    )
    clear_enqueued_jobs
    Rails.cache.clear

    travel_to(Date.new(2026, 1, 1)) { build_job.perform(@backfill) }

    portfolio_user_ids = enqueued_jobs.filter_map do |job|
      job[:args].first["user_id"] if job[:job] == BuildPortfolioPerformanceObservationsJob
    end
    assert_includes portfolio_user_ids, income_owner.id

    instrument_targets = enqueued_jobs.filter_map do |job|
      job[:args].first if job[:job] == BuildInstrumentPerformanceObservationsJob
    end
    assert instrument_targets.any? { |arguments|
      arguments["user_id"] == income_owner.id && arguments["instrument_id"] == @instrument.id
    }
  end

  test "rebuilds an instrument whose trade settled in the backfill currency" do
    user = users(:owner)
    user.update!(reporting_currency: "EUR")
    settled_instrument = Instrument.create!(ticker: "SETTLED", exchange: "XNAS", name: "Settled ETF", currency: "USD")
    backfill_instrument = Instrument.create!(ticker: "EURO", exchange: "XETR", name: "Euro ETF", currency: "EUR")
    unrelated_instrument = Instrument.create!(ticker: "UNRELATED", exchange: "BVMF", name: "Unrelated stock", currency: "BRL")
    user.trades.create!(instrument: settled_instrument, side: :buy, traded_on: Date.new(2026, 1, 1),
      quantity: 1, unit_price: 10, currency: "USD", settlement_exchange_rate: "0.92")
    user.trades.create!(instrument: unrelated_instrument, side: :buy, traded_on: Date.new(2026, 1, 1),
      quantity: 1, unit_price: 10, currency: "BRL")
    backfill = HistoricalDataBackfill.create!(instrument: backfill_instrument, currency: "EUR",
      from_date: Date.new(2026, 1, 1))
    clear_enqueued_jobs
    Rails.cache.clear

    travel_to(Date.new(2026, 1, 1)) { build_job.perform(backfill) }

    instrument_jobs = enqueued_jobs.select { |job| job[:job] == BuildInstrumentPerformanceObservationsJob }
    assert_includes instrument_jobs.map { |job| job[:args].first.slice("instrument_id", "reporting_currency") },
      { "instrument_id" => settled_instrument.id, "reporting_currency" => "USD" }
    refute_includes instrument_jobs.map { |job| job[:args].first.slice("instrument_id", "reporting_currency") },
      { "instrument_id" => settled_instrument.id, "reporting_currency" => "EUR" }
  end

  test "imports FX for every reporting currency used by an instrument in multi mode" do
    users(:one).update!(reporting_currency: "EUR")

    with_stubbed_method(Caramelo::AccountMode, :multi?, -> { true }) do
      with_stubbed_method(Caramelo::AccountMode, :single?, -> { false }) do
        travel_to(Date.new(2026, 1, 1)) { build_job.perform(@backfill) }
      end
    end

    assert_equal %w[BRL EUR], @exchange_rate_imports.map { |call| call.fetch(:quote_currency) }.uniq.sort
  end

  test "imports FX for a distinct reporting currency used by another affected user" do
    other_user = users(:two)
    other_user.update!(reporting_currency: "USD")
    settled_instrument = Instrument.create!(ticker: "SETTLEDGBP", exchange: "XNAS", name: "Settled GBP ETF", currency: "EUR")
    other_user.trades.create!(instrument: settled_instrument, side: :buy, traded_on: Date.new(2026, 1, 1),
      quantity: 1, unit_price: 10, currency: "EUR", settlement_currency: "USD", settlement_exchange_rate: "1.1")
    other_user.update!(reporting_currency: "GBP")
    clear_enqueued_jobs
    Rails.cache.clear

    with_stubbed_method(Caramelo::AccountMode, :multi?, -> { true }) do
      with_stubbed_method(Caramelo::AccountMode, :single?, -> { false }) do
        travel_to(Date.new(2026, 1, 1)) { build_job.perform(@backfill) }
      end
    end

    assert_includes @exchange_rate_imports.map { |call| call.fetch(:quote_currency) }, "GBP"
  end

  test "falls back to the configured owner currency when an instrument has no account activity" do
    instrument = Instrument.create!(ticker: "EMPTY", exchange: "XNAS", name: "Empty instrument", currency: "USD")
    job = BackfillHistoricalMarketDataJob.new

    with_stubbed_method(Caramelo::AccountMode, :multi?, -> { true }) do
      with_stubbed_method(Caramelo::AccountMode, :single?, -> { false }) do
        assert_equal [ User.owner.reporting_currency ], job.send(:reporting_currencies_for, instrument)
      end
    end
  end

  test "reports terminal provider errors and clears the pending request" do
    job = build_job
    error = MarketData::YahooFinance::InvalidResponse.new("malformed response")
    @daily_importer.define_singleton_method(:call) { |**| raise error }
    reports = []

    with_stubbed_method(Rails.error, :report, ->(reported_error, **context) { reports << [ reported_error, context ] }) do
      job.perform(@backfill)
    end

    assert_equal error, reports.sole.first
    assert_equal @backfill.id, reports.sole.last.fetch(:context).fetch(:historical_data_backfill_id)
    assert_not HistoricalDataBackfill.exists?(@backfill.id)
  end

  test "leaves the request for Active Job to retry a temporary provider error" do
    job = build_job
    error = MarketData::YahooFinance::ProviderUnavailable.new(status: 503)
    @daily_importer.define_singleton_method(:call) { |**| raise error }

    assert_raises(MarketData::YahooFinance::ProviderUnavailable) { job.perform(@backfill) }

    assert HistoricalDataBackfill.exists?(@backfill.id)
  end

  test "reports and clears the request when temporary provider retries are exhausted" do
    job = build_job
    error = MarketData::YahooFinance::ProviderUnavailable.new(status: 503)
    @daily_importer.define_singleton_method(:call) { |**| raise error }
    job.arguments = [ @backfill ]
    job.exception_executions[retry_exceptions.to_s] = BackfillHistoricalMarketDataJob::RETRY_ATTEMPTS - 1
    reports = []

    with_stubbed_method(Rails.error, :report, ->(reported_error, **context) { reports << [ reported_error, context ] }) do
      job.perform_now
    end

    assert_equal error, reports.sole.first
    assert_equal @backfill.id, reports.sole.last.fetch(:context).fetch(:historical_data_backfill_id)
    assert_not HistoricalDataBackfill.exists?(@backfill.id)
  end

  private

  def build_job
    @daily_importer = Object.new
    daily_imports = @daily_imports
    @daily_importer.define_singleton_method(:call) { |**arguments| daily_imports << arguments }
    @exchange_rate_importer = Object.new
    exchange_rate_imports = @exchange_rate_imports
    @exchange_rate_importer.define_singleton_method(:call) { |**arguments| exchange_rate_imports << arguments }
    throttle = Object.new
    waits = @waits
    throttle.define_singleton_method(:wait!) { |instrument: nil| waits << instrument }

    daily_importer = @daily_importer
    historical_exchange_rate_importer = @exchange_rate_importer

    BackfillHistoricalMarketDataJob.new.tap do |job|
      job.define_singleton_method(:daily_closing_price_importer) { daily_importer }
      job.define_singleton_method(:historical_exchange_rate_importer) { historical_exchange_rate_importer }
      job.define_singleton_method(:request_throttle) { throttle }
    end
  end

  def retry_exceptions
    [
      MarketData::YahooFinance::TransportError,
      MarketData::YahooFinance::RateLimited,
      MarketData::YahooFinance::ProviderUnavailable
    ]
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    object.singleton_class.define_method(method_name, original)
  end
end
