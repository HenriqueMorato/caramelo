require "test_helper"

class ReportingCurrency::PreparationTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    @user = users(:owner)
    @user.update!(reporting_currency: "EUR")
    @refreshes = []
    @imports = []
    @waits = []
    refreshes, imports, waits = @refreshes, @imports, @waits
    @exchange_rates = Object.new
    @exchange_rates.define_singleton_method(:read) do |**|
      ExchangeRateCache::Lookup.new(exchange_rate: nil, status: :missing)
    end
    @exchange_rates.define_singleton_method(:refresh) { |**args| refreshes << args }
    @history = Object.new
    @history.define_singleton_method(:call) { |**args| imports << args }
    @throttle = Object.new
    @throttle.define_singleton_method(:wait!) { waits << true }
  end

  test "prepares current FX and bounded missing history then enqueues the selected currency rebuild" do
    travel_to(Date.new(2026, 8, 14)) { preparation.call }

    assert_equal [ { base_currency: "USD", quote_currency: "EUR" } ], @refreshes
    assert_equal 1, @imports.size
    assert_equal Date.new(2026, 8, 5), @imports.first[:from]
    assert_equal Date.new(2026, 8, 14), @imports.first[:to]
    assert_equal false, @imports.first[:enqueue_performance_rebuild]
    assert_equal 2, @waits.size
    assert_enqueued_with(job: BuildPortfolioPerformanceObservationsJob,
      args: ->(args) { args.first[:reporting_currency] == "EUR" })
    assert_enqueued_with(job: BuildInstrumentPerformanceObservationsJob,
      args: ->(args) { args.first[:reporting_currency] == "EUR" && args.first[:instrument_id] == instruments(:voo_arcx).id })
  end

  test "does not refetch fresh current FX or overwrite direct and inverse history" do
    @exchange_rates.define_singleton_method(:read) do |**|
      ExchangeRateCache::Lookup.new(exchange_rate: nil, status: :fresh)
    end
    create_rate(Date.new(2026, 8, 7))
    create_rate(Date.new(2026, 8, 10), inverse: true)
    original = HistoricalExchangeRate.order(:id).map(&:attributes)

    travel_to(Date.new(2026, 8, 14)) { preparation.call }

    assert_empty @refreshes
    assert_equal [ Date.new(2026, 8, 5)..Date.new(2026, 8, 6),
      Date.new(2026, 8, 11)..Date.new(2026, 8, 14) ], @imports.map { |call| call[:from]..call[:to] }
    assert_equal original, HistoricalExchangeRate.order(:id).map(&:attributes)
  end

  test "does not fetch weekends or refetch a complete history" do
    TradingCalendar.weekdays_between(Date.new(2026, 8, 5), Date.new(2026, 8, 14)).each { |date| create_rate(date) }

    travel_to(Date.new(2026, 8, 16)) { preparation.call }

    assert_empty @imports
  end

  test "splits long history into bounded batches and ignores another owner's currencies" do
    other_instrument = instruments(:petr4_bvmf)
    users(:two).trades.create!(instrument: other_instrument, traded_on: Date.new(2020, 1, 1),
      side: :buy, quantity: 1, unit_price: 1, currency: "BRL")

    travel_to(Date.new(2027, 8, 12)) { preparation.call }

    assert_operator @imports.size, :>, 1
    assert_equal [ "USD" ], @imports.map { |call| call[:base_currency] }.uniq
    @imports.each do |call|
      assert_operator TradingCalendar.weekdays_between(call[:from], call[:to]).size, :<=,
        ReportingCurrency::Preparation::HISTORY_BATCH_SIZE
    end
  end

  test "rebuilds same-currency holdings without fetching FX" do
    @user.update!(reporting_currency: "USD")

    travel_to(Date.new(2026, 8, 14)) { preparation.call }

    assert_empty @imports
    assert_empty @refreshes
    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
    assert_enqueued_jobs 1, only: BuildInstrumentPerformanceObservationsJob
  end

  test "prepares the captured settlement currency after a reporting currency change" do
    @user.update!(reporting_currency: "BRL")
    trades(:owner_voo_buy).update!(settlement_exchange_rate: "5.25")
    @user.update!(reporting_currency: "EUR")

    travel_to(Date.new(2026, 8, 14)) { preparation.call }

    assert_equal [
      { base_currency: "BRL", quote_currency: "EUR" },
      { base_currency: "USD", quote_currency: "EUR" }
    ], @refreshes.sort_by { |pair| pair[:base_currency] }
    assert_equal %w[BRL USD], @imports.map { |call| call[:base_currency] }.sort
  end

  test "uses the earliest native or settlement trade date for each currency" do
    @user.update!(reporting_currency: "BRL")
    trades(:owner_voo_buy).update!(settlement_exchange_rate: "5.25")
    early_native_trade = @user.trades.create!(
      instrument: instruments(:petr4_bvmf), side: :buy, traded_on: Date.new(2026, 8, 1),
      quantity: 1, unit_price: 1, currency: "BRL"
    )
    @user.update!(reporting_currency: "EUR")

    starts = preparation.send(:currency_starts)

    assert_equal early_native_trade.traded_on, starts.fetch("BRL")
  end

  test "an empty portfolio requires neither FX nor a rebuild" do
    @user = users(:two)

    preparation.call

    assert_empty @imports
    assert_empty @refreshes
    assert_no_enqueued_jobs only: BuildPortfolioPerformanceObservationsJob
  end

  test "reports failed preparation without publishing a successful rebuild" do
    @history.define_singleton_method(:call) { |**| raise ExchangeRate::InvalidValue, "provider unavailable" }

    assert_raises(ExchangeRate::InvalidValue) { preparation.call }

    assert_predicate RefreshStatus::State.read("reporting_currency:#{@user.id}:EUR"), :failed?
    assert_no_enqueued_jobs only: BuildPortfolioPerformanceObservationsJob
  end

  test "failed rebuild enqueue leaves preparation failed and retryable" do
    original = Performance::SeriesRefresh.method(:enqueue)
    Performance::SeriesRefresh.define_singleton_method(:enqueue) { |**| :failed }

    assert_raises(ActiveJob::EnqueueError) { preparation.call }
    assert_predicate RefreshStatus::State.read("reporting_currency:#{@user.id}:EUR"), :failed?
  ensure
    Performance::SeriesRefresh.define_singleton_method(:enqueue, original)
  end

  test "failed instrument rebuild enqueue leaves preparation failed and retryable" do
    original = Performance::SeriesRefresh.method(:enqueue)
    calls = 0
    Performance::SeriesRefresh.define_singleton_method(:enqueue) do |**|
      calls += 1
      calls == 1 ? :queued : :failed
    end

    error = assert_raises(ActiveJob::EnqueueError) { preparation.call }

    assert_equal "instrument performance rebuild could not be enqueued", error.message
    assert_predicate RefreshStatus::State.read("reporting_currency:#{@user.id}:EUR"), :failed?
  ensure
    Performance::SeriesRefresh.define_singleton_method(:enqueue, original)
  end

  private

  def preparation
    ReportingCurrency::Preparation.new(user: @user, currency: @user.reporting_currency,
      exchange_rates: @exchange_rates, history: @history, throttle: @throttle)
  end

  def create_rate(date, inverse: false)
    base_currency, quote_currency = inverse ? %w[EUR USD] : %w[USD EUR]
    HistoricalExchangeRate.create!(base_currency:, quote_currency:, rate_date: date, rate: "1",
      provider: HistoricalExchangeRate::Providers::YahooFinance::IDENTIFIER,
      observed_at: Time.current, fetched_at: Time.current)
  end
end
