require "test_helper"

class HistoricalExchangeRate::ImporterTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @provider = FakeProvider.new
    @importer = HistoricalExchangeRate::Importer.new(provider: @provider)
  end

  test "persists observations and reports missing weekdays" do
    result = @importer.call(base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26))

    assert_equal 2, result.created_count
    assert_equal [ Date.new(2026, 8, 25) ], result.missing_dates
  end

  test "updates corrections without duplicates" do
    @importer.call(base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24))
    @provider.rate = BigDecimal("6")
    result = @importer.call(base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24))

    assert_equal 0, result.created_count
    assert_equal 1, result.updated_count
    assert_equal BigDecimal("6"), HistoricalExchangeRate.first.rate
  end

  test "normalizes the pair before requesting observations" do
    @importer.call(base_currency: " usd ", quote_currency: "brl", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24))

    assert_equal [ "USD", "BRL" ], @provider.requested_pair
  end

  test "an inverse-rate correction invalidates and rebuilds dependent portfolio values" do
    user = users(:owner)
    date = Date.new(2026, 8, 24)
    trade = trades(:owner_voo_buy)
    trade.update_columns(traded_on: date)
    @provider.define_singleton_method(:identifier) { MarketData::YahooFinance::FX_CONFIGURATION.identifier }
    @provider.rate = BigDecimal("0.2")
    @importer.call(base_currency: "BRL", quote_currency: "USD", from: date, to: date)
    DailyClosingPrice.create!(
      instrument: trade.instrument, trading_date: date, close_price: "100", currency: "USD",
      provider: "yahoo_finance", observed_at: date.to_time
    )
    Performance::ObservationBuilder.new(user:).call(from: date, to: date)
    observation = user.portfolio_performance_observations.find_by!(observed_on: date)
    assert_equal BigDecimal("1250"), observation.market_value_amount

    @provider.rate = BigDecimal("0.25")
    @importer.call(base_currency: "BRL", quote_currency: "USD", from: date, to: date)

    assert_predicate observation.reload, :stale?
    assert_predicate PortfolioPerformanceMaterialization.for(user:), :pending?
    Performance::ObservationBuilder.new(user:).call(from: date, to: date)
    assert_equal BigDecimal("1000"), observation.reload.market_value_amount
    assert_not_predicate observation, :stale?
  end

  test "returns missing weekdays without invalidating performance when the provider has no observations" do
    date = Date.new(2026, 8, 25)

    result = @importer.call(
      base_currency: "USD", quote_currency: "BRL", from: date, to: date
    )

    assert_equal [ date ], result.missing_dates
    assert_equal 0, result.created_count
    assert_equal 0, result.updated_count
  end

  test "rolls back earlier rates when a later row is invalid" do
    fetch = @provider.method(:fetch)
    @provider.define_singleton_method(:fetch) do |**arguments|
      fetch.call(**arguments).each_with_index.map do |observation, index|
        index.zero? ? observation : observation.with(rate: BigDecimal("-1"))
      end
    end

    assert_raises(ActiveRecord::RecordInvalid) do
      @importer.call(
        base_currency: "USD", quote_currency: "BRL",
        from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26)
      )
    end

    assert_empty HistoricalExchangeRate.all
  end

  test "keeps durable dirty history without enqueueing while a backfill batch is incomplete" do
    @importer.call(
      base_currency: "USD", quote_currency: "BRL",
      from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26),
      enqueue_performance_rebuild: false
    )

    assert_predicate PortfolioPerformanceMaterialization.for(user: users(:owner)), :pending?
    assert_nil Performance::SeriesRefresh.read(user: users(:owner))
  end

  test "rejects inverted and future ranges" do
    assert_raises(ArgumentError) do
      @importer.call(base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 25), to: Date.new(2026, 8, 24))
    end
    assert_raises(ArgumentError) do
      @importer.call(base_currency: "USD", quote_currency: "BRL", from: Date.current, to: Date.current + 1)
    end
  end

  test "rejects same-currency and invalid currency pairs" do
    assert_raises(ArgumentError) do
      @importer.call(base_currency: "USD", quote_currency: "USD", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24))
    end
    assert_raises(ArgumentError) do
      @importer.call(base_currency: "XXX", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24))
    end
  end

  test "rejects observations outside the requested range" do
    @provider.include_out_of_range = true

    assert_raises(ArgumentError) do
      @importer.call(base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24))
    end
  end

  test "rejects non-date ranges and mismatched observations" do
    assert_raises(ArgumentError) do
      @importer.call(base_currency: "USD", quote_currency: "BRL", from: "2026-08-24", to: Date.new(2026, 8, 24))
    end

    @provider.mismatch_pair = true
    assert_raises(ArgumentError) do
      @importer.call(base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24))
    end
  end

  test "uses the default Yahoo provider" do
    assert_instance_of HistoricalExchangeRate::Providers::YahooFinance, HistoricalExchangeRate::Importer.default.send(:provider)
  end

  test "handles a concurrent insert by updating the existing row" do
    record = FakeRecord.new(new_record: true, error: ActiveRecord::RecordNotUnique)
    existing = FakeRecord.new(new_record: false)
    with_stubbed_class_method(HistoricalExchangeRate, :find_or_initialize_by, ->(**) { record }) do
      with_stubbed_class_method(HistoricalExchangeRate, :find_by!, ->(**) { existing }) do
        result = @importer.call(base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24))

        assert_equal 1, result.updated_count
        assert_equal 1, existing.updates
      end
    end
  end

  test "rejects duplicate observation dates" do
    @provider.duplicate_dates = true

    assert_raises(ArgumentError) do
      @importer.call(base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24))
    end
  end

  private

  class FakeProvider
    attr_accessor :rate
    attr_reader :requested_pair
    attr_accessor :include_out_of_range
    attr_accessor :mismatch_pair
    attr_accessor :duplicate_dates

    def initialize
      @rate = BigDecimal("5")
      @include_out_of_range = false
      @mismatch_pair = false
      @duplicate_dates = false
    end

    def identifier = "test_provider"

    def fetch(base_currency:, quote_currency:, from:, to:)
      @requested_pair = [ base_currency, quote_currency ]
      dates = duplicate_dates ? [ from, from ] : [ from, to ].uniq
      dates << from + 2 if include_out_of_range
      dates.filter_map do |date|
        next unless date.wday == 1 || date.wday == 3

        HistoricalExchangeRate::Observation.new(
          base_currency: mismatch_pair ? "EUR" : base_currency, quote_currency:, rate_date: date, rate:, provider: identifier,
          observed_at: date.to_time, fetched_at: Time.current
        )
      end
    end
  end

  class FakeRecord
    attr_reader :updates

    def initialize(new_record:, error: nil)
      @new_record = new_record
      @error = error
      @updates = 0
    end

    def new_record? = @new_record

    def update!(**)
      raise @error if @error

      @updates += 1
    end
  end

  def with_stubbed_class_method(klass, method_name, replacement)
    original = klass.method(method_name)
    klass.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    klass.singleton_class.define_method(method_name, original)
  end
end
