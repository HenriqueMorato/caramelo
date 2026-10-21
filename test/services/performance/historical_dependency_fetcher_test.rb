require "test_helper"

class Performance::HistoricalDependencyFetcherTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @user = User.create!(email_address: "dependency-fetcher@example.com", password: "password")
    @user.update!(reporting_currency: "USD")
    @instrument = Instrument.create!(ticker: "IWDA", exchange: "XETR", name: "iShares Core MSCI World", currency: "EUR")
    @from = Date.new(2026, 9, 19)
    @to = Date.new(2026, 10, 15)
    @user.trades.create!(instrument: @instrument, side: :buy, traded_on: @from,
      quantity: 2, unit_price: 100, fees_cents: 0, currency: "EUR")
    @price_importer = RecordingImporter.new do |arguments|
      TradingCalendar.weekdays_between(arguments.fetch(:from), arguments.fetch(:to)).each do |date|
        DailyClosingPrice.find_or_initialize_by(
          instrument: arguments.fetch(:instrument), trading_date: date,
          provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier
        ).update!(
          close_price: "100",
          currency: arguments.fetch(:instrument).currency,
          provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier,
          observed_at: date.to_time
        )
      end
    end
    @rate_importer = RecordingImporter.new do |arguments|
      TradingCalendar.weekdays_between(arguments.fetch(:from), arguments.fetch(:to)).each do |date|
        HistoricalExchangeRate.find_or_initialize_by(
          base_currency: arguments.fetch(:base_currency), quote_currency: arguments.fetch(:quote_currency),
          rate_date: date, provider: MarketData::YahooFinance::FX_CONFIGURATION.identifier
        ).update!(
          rate: "1.1",
          observed_at: date.to_time, fetched_at: date.to_time
        )
      end
    end
  end

  test "fetches missing prices and rates before the performance rebuild" do
    requirements = Performance::HistoricalDependencyFetcher.call(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer,
      from: @from, to: @to
    )

    assert_equal 1, @price_importer.calls.size
    assert_equal 1, @rate_importer.calls.size
    assert_equal [ "IWDA", "EUR", "USD" ], [
      requirements.find { |item| item.respond_to?(:instrument) }.instrument.ticker,
      requirements.find { |item| item.respond_to?(:base_currency) }.base_currency,
      requirements.find { |item| item.respond_to?(:quote_currency) }.quote_currency
    ]
    assert_equal @from - 7.days, @price_importer.calls.first.fetch(:from)
    assert_equal @from - 7.days, @rate_importer.calls.first.fetch(:from)
  end

  test "throttles provider requests and fences source publication" do
    throttle = RecordingThrottle.new

    Performance::HistoricalDependencyFetcher.call(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer, throttle:,
      from: @from, to: @to
    )

    assert_equal [ @instrument, nil ], throttle.instruments
    assert_instance_of MarketData::PublicationFence, @price_importer.calls.first.fetch(:fence)
    assert_instance_of MarketData::PublicationFence, @rate_importer.calls.first.fetch(:fence)
  end

  test "keeps one publication generation across provider chunks" do
    fetcher = Performance::HistoricalDependencyFetcher.new(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer
    )
    fetcher.instance_variable_set(:@from, @from)
    fetcher.instance_variable_set(:@to, @to)
    requirement = Performance::HistoricalDependencyFetcher::PriceRequirement.new(
      instrument: @instrument, dates: [ @from, @to ]
    )
    fetcher.define_singleton_method(:bounded_ranges) do |_ranges|
      [ @from..@from, @to..@to ]
    end

    fetcher.send(:fetch, requirement, refetch_full_range: false)

    assert_equal 2, @price_importer.calls.size
    assert_equal 1, @price_importer.calls.map { |call| call.fetch(:generation) }.uniq.size
  end

  test "reports the exact dependencies that remain unavailable" do
    error = assert_raises(Performance::HistoricalDependencyFetcher::Unavailable) do
      Performance::HistoricalDependencyFetcher.call(
        user: @user, instrument: @instrument, reporting_currency: "USD",
        price_importer: RecordingImporter.new, rate_importer: RecordingImporter.new,
        from: @from, to: @to
      )
    end

    assert_includes error.message, "IWDA historical closing prices missing"
    assert_includes error.message, "EUR/USD historical exchange rates missing"
    assert_includes error.message, "2026-09-19"
  end

  test "refetches the complete dependency range even when source rows exist" do
    TradingCalendar.weekdays_between(@from - 7.days, @to).each do |date|
      DailyClosingPrice.create!(
        instrument: @instrument, trading_date: date, close_price: "100", currency: "EUR",
        provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier, observed_at: date.to_time
      )
      HistoricalExchangeRate.create!(
        base_currency: "EUR", quote_currency: "USD", rate_date: date, rate: "1.1",
        provider: MarketData::YahooFinance::FX_CONFIGURATION.identifier,
        observed_at: date.to_time, fetched_at: date.to_time
      )
    end

    Performance::HistoricalDependencyFetcher.call(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer,
      from: @from, to: @to, refetch_full_range: true
    )

    assert_equal [ @from - 7.days, @to ], @price_importer.calls.first.values_at(:from, :to)
    assert_equal [ @from - 7.days, @to ], @rate_importer.calls.first.values_at(:from, :to)
  end

  test "does not refetch dependencies that already have an eligible observation" do
    Performance::HistoricalDependencyFetcher.call(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer,
      from: @from, to: @to
    )
    @price_importer.calls.clear
    @rate_importer.calls.clear

    Performance::HistoricalDependencyFetcher.call(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer,
      from: @from, to: @to
    )

    assert_empty @price_importer.calls
    assert_empty @rate_importer.calls
  end

  test "keeps a targeted retry scoped to the requested instrument and currency" do
    calls = []
    with_stubbed_method(Performance::ObservationInvalidator, :enqueue, ->(**arguments) { calls << [ :portfolio, arguments ]; :queued }) do
      with_stubbed_method(Performance::ObservationInvalidator, :enqueue_instrument, ->(**arguments) {
        calls << [ :instrument, arguments ]
        :queued
      }) do
        Performance::HistoricalDependencyFetcher.call(
          user: @user, instrument: @instrument, reporting_currency: "USD",
          price_importer: @price_importer, rate_importer: @rate_importer,
          from: @from, to: @to
        )
      end
    end

    assert_equal [ :portfolio, :instrument ], calls.map(&:first)
    assert_equal @instrument, calls.last.last.fetch(:instrument)
    assert_equal "USD", calls.last.last.fetch(:reporting_currency)
  end

  test "returns no requirements for an instrument without a position" do
    empty_instrument = Instrument.create!(ticker: "EMPTY", exchange: "XNAS", name: "No position", currency: "USD")

    requirements = Performance::HistoricalDependencyFetcher.call(
      user: @user, instrument: empty_instrument, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer,
      from: @from, to: @to
    )

    assert_empty requirements
    assert_empty @price_importer.calls
    assert_empty @rate_importer.calls
  end

  test "supports portfolio dependencies, native prices, cash actions, and cash in lieu" do
    @user.trades.create!(instrument: instruments(:voo_arcx), side: :buy, traded_on: @from,
      quantity: 1, unit_price: 100, fees_cents: 0, currency: "USD")
    @user.corporate_actions.create!(
      instrument: @instrument, kind: :dividend, ex_date: @from, paid_on: @from + 1.day,
      gross_amount_cents: 100, withholding_tax_cents: 0, net_amount_cents: 100,
      currency: "EUR", source: "manual"
    )
    @user.corporate_actions.create!(
      instrument: @instrument, kind: :stock_split, effective_on: @from + 2.days,
      ratio_numerator: 2, ratio_denominator: 1, cash_in_lieu_quantity: "0.5",
      cash_in_lieu_amount_cents: 25, currency: "EUR", source: "manual"
    )
    @user.corporate_actions.create!(
      instrument: @instrument, kind: :reverse_split, effective_on: @from + 3.days,
      ratio_numerator: 1, ratio_denominator: 2, source: "manual"
    )
    assert_predicate @user.corporate_actions.find_by(kind: :stock_split), :cash_in_lieu?

    requirements = Performance::HistoricalDependencyFetcher.call(
      user: @user, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer,
      from: @from, to: @to
    )

    assert requirements.any? { |item| item.respond_to?(:instrument) && item.instrument == @instrument }
    assert requirements.any? { |item| item.respond_to?(:instrument) && item.instrument == instruments(:voo_arcx) }
    assert_includes @rate_importer.calls.map { |call| [ call[:base_currency], call[:quote_currency] ] }, [ "EUR", "USD" ]
  end

  test "uses explicit settlement currency and falls back to trade quantities after invalid data" do
    @user.update!(reporting_currency: "GBP")
    @user.trades.create!(instrument: @instrument, side: :buy, traded_on: @from + 1.day,
      quantity: 1, unit_price: 100, fees_cents: 0, currency: "EUR", settlement_exchange_rate: "1.2")
    @user.update!(reporting_currency: "USD")
    assert_predicate @user.trades.order(:id).last, :explicit_settlement_conversion?

    Performance::HistoricalDependencyFetcher.call(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer,
      from: @from, to: @to
    )

    invalid_user = User.create!(email_address: "invalid-dependency-fetcher@example.com", password: "password")
    invalid_user.update!(reporting_currency: "USD")
    invalid_instrument = Instrument.create!(ticker: "BAD", exchange: "XNAS", name: "Invalid data", currency: "EUR")
    invalid_user.trades.create!(instrument: invalid_instrument, side: :sell, traded_on: @from,
      quantity: 1, unit_price: 100, fees_cents: 0, currency: "EUR")
    invalid_user.trades.create!(instrument: invalid_instrument, side: :buy, traded_on: @from + 1.day,
      quantity: 2, unit_price: 100, fees_cents: 0, currency: "EUR")

    fetcher = Performance::HistoricalDependencyFetcher.new(
      user: invalid_user, instrument: invalid_instrument, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer
    )
    fetcher.call(from: @from, to: @to)

    fetcher.call(from: @from + 3.days, to: @to)

    normal_fetcher = Performance::HistoricalDependencyFetcher.new(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer
    )
    normal_fetcher.instance_variable_set(:@from, @from)
    normal_fetcher.instance_variable_set(:@to, @to)
    normal_fetcher.send(:open_position_dates, @instrument)
    normal_fetcher.instance_variable_set(:@from, @from + 3.days)
    normal_fetcher.send(:open_position_dates, @instrument)

    assert_includes @rate_importer.calls.map { |call| [ call[:base_currency], call[:quote_currency] ] }, [ "EUR", "USD" ]
    assert_equal "GBP", @user.trades.order(:id).last.settlement_currency
  end

  test "rejects future and reversed ranges" do
    fetcher = Performance::HistoricalDependencyFetcher.new(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer
    )

    assert_raises(ArgumentError) { fetcher.call(from: @to, to: @from) }
    assert_raises(ArgumentError) { fetcher.call(from: Date.current + 1.day, to: Date.current + 1.day) }
    assert_raises(ArgumentError) do
      fetcher.call(from: Date.new(1900, 1, 1), to: Date.current)
    end
  end

  test "coalesces overlapping fetch ranges" do
    fetcher = Performance::HistoricalDependencyFetcher.new(
      user: @user, reporting_currency: "USD", price_importer: @price_importer, rate_importer: @rate_importer
    )
    ranges = fetcher.send(:ranges_for, [ Date.new(2026, 9, 19), Date.new(2026, 9, 27) ])

    assert_equal [ Date.new(2026, 9, 12)..Date.new(2026, 9, 27) ], ranges
  end

  test "bounds long internal dependency ranges into provider-sized chunks" do
    fetcher = Performance::HistoricalDependencyFetcher.new(
      user: @user, reporting_currency: "USD", price_importer: @price_importer, rate_importer: @rate_importer
    )
    range = Date.new(1950, 1, 1)..Date.new(2026, 10, 15)

    ranges = fetcher.send(:bounded_ranges, [ range ])

    assert_operator ranges.size, :>, 1
    assert ranges.all? { |bounded| (bounded.end - bounded.begin).to_i <= Performance::HistoricalDependencyFetcher::MAX_RANGE_DAYS }
    assert_equal range.begin, ranges.first.begin
    assert_equal range.end, ranges.last.end
  end

  test "ignores blank and native dependency currencies" do
    fetcher = Performance::HistoricalDependencyFetcher.new(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer
    )
    dates = Hash.new { |hash, pair| hash[pair] = Set.new }

    fetcher.send(:add_dates, dates, "USD", [ @from ])
    fetcher.send(:add_dates, dates, nil, [ @from ])
    fetcher.send(:add_date, dates, nil, @from)
    fetcher.send(:add_date, dates, "EUR", nil)

    assert_empty dates
  end

  test "does not report dates after a position has closed" do
    fetcher = Performance::HistoricalDependencyFetcher.new(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      price_importer: @price_importer, rate_importer: @rate_importer
    )
    fetcher.instance_variable_set(:@from, @from)
    fetcher.instance_variable_set(:@to, @to)

    dates = fetcher.send(:open_dates_from_timeline, @from, { @from => 0.to_r })

    assert_empty dates
  end

  class RecordingImporter
    attr_reader :calls

    def initialize(&block)
      @calls = []
      @block = block
    end

    def call(**arguments)
      calls << arguments
      @block&.call(arguments)
    end
  end

  class RecordingThrottle
    attr_reader :instruments

    def initialize
      @instruments = []
    end

    def wait!(instrument: nil)
      instruments << instrument
    end
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name) { |*args, **kwargs| replacement.call(*args, **kwargs) }
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
