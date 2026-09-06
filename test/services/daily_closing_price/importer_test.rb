require "test_helper"

class DailyClosingPrice::ImporterTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @instrument = instruments(:voo_arcx)
    @provider = FakeProvider.new
    @importer = DailyClosingPrice::Importer.new(provider: @provider)
  end

  test "persists observations and reports missing weekdays" do
    result = @importer.call(instrument: @instrument, from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26))

    assert_equal 2, result.created_count
    assert_equal [ Date.new(2026, 8, 25) ], result.missing_dates
    assert_equal 2, DailyClosingPrice.where(instrument: @instrument).count
    assert_equal [ Date.new(2026, 8, 24), Date.new(2026, 8, 26) ], DailyClosingPrice.chronological.pluck(:trading_date)
  end

  test "updates a corrected observation without duplicating it" do
    @importer.call(instrument: @instrument, from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26))
    @provider.price = BigDecimal("505.12345678")

    result = @importer.call(instrument: @instrument, from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26))

    assert_equal 0, result.created_count
    assert_equal 2, result.updated_count
    assert_equal BigDecimal("505.12345678"), DailyClosingPrice.find_by!(instrument: @instrument, trading_date: Date.new(2026, 8, 24)).close_price
    assert_equal 2, DailyClosingPrice.where(instrument: @instrument).count
  end

  test "updates the existing row when a concurrent insert wins the unique index" do
    @importer.call(instrument: @instrument, from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24))
    observation = DailyClosingPrice::Observation.new(
      instrument: @instrument, trading_date: Date.new(2026, 8, 24), close_price: BigDecimal("501.12345678"),
      currency: "USD", provider: "fake_provider", observed_at: Time.current
    )
    concurrent_record = Object.new
    concurrent_record.define_singleton_method(:new_record?) { true }
    concurrent_record.define_singleton_method(:update!) { |**| raise ActiveRecord::RecordNotUnique }

    @importer.send(:persist_observation, concurrent_record, observation)

    assert_equal BigDecimal("501.12345678"), DailyClosingPrice.find_by!(instrument: @instrument, trading_date: observation.trading_date).close_price
  end

  test "does not copy current-price cache entries" do
    CurrentMarketPriceCache.new.write(
      instrument: @instrument,
      current_market_price: CurrentMarketPrice.new(
        unit_price: "500", currency: "USD", provider: "yahoo_finance",
        quoted_at: Time.current, fetched_at: Time.current
      )
    )

    assert_empty DailyClosingPrice.where(instrument: @instrument)
  end

  test "returns missing weekdays without invalidating performance when the provider has no observations" do
    date = Date.new(2026, 8, 25)

    result = @importer.call(instrument: @instrument, from: date, to: date)

    assert_equal [ date ], result.missing_dates
    assert_equal 0, result.created_count
    assert_equal 0, result.updated_count
  end

  test "skips persistence when a newer publication generation wins" do
    fence = Object.new
    fence.define_singleton_method(:capture) { "generation-1" }
    fence.define_singleton_method(:publish) { |generation| :superseded }

    result = @importer.call(instrument: @instrument, from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24), fence:)

    assert_equal 0, result.created_count
    assert_empty DailyClosingPrice.where(instrument: @instrument)
  end

  test "persists inside the fence when its generation is current" do
    fence = Object.new
    fence.define_singleton_method(:capture) { "generation-1" }
    fence.define_singleton_method(:publish) { |generation, &block| block.call; :published }

    result = @importer.call(instrument: @instrument, from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24), fence:)

    assert_equal 1, result.created_count
    assert_predicate DailyClosingPrice.find_by(instrument: @instrument), :present?
  end

  test "rolls back earlier observations when a later row is invalid" do
    fetch = @provider.method(:fetch)
    @provider.define_singleton_method(:fetch) do |**arguments|
      fetch.call(**arguments).each_with_index.map do |observation, index|
        index.zero? ? observation : observation.with(close_price: BigDecimal("-1"))
      end
    end

    assert_raises(ActiveRecord::RecordInvalid) do
      @importer.call(instrument: @instrument, from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26))
    end

    assert_empty DailyClosingPrice.where(instrument: @instrument)
  end

  test "keeps durable dirty history without enqueueing while a backfill batch is incomplete" do
    @importer.call(
      instrument: @instrument, from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26),
      enqueue_performance_rebuild: false
    )

    assert_predicate PortfolioPerformanceMaterialization.for(user: users(:owner)), :pending?
    assert_nil Performance::SeriesRefresh.read(user: users(:owner))
  end

  test "rolls back imported prices and dirty metadata together if invalidation fails" do
    state = PortfolioPerformanceMaterialization.for(user: users(:owner))
    original = Performance::ObservationInvalidator.method(:mark!)
    Performance::ObservationInvalidator.define_singleton_method(:mark!, lambda { |**arguments|
      original.call(**arguments)
      raise "invalidation unavailable"
    })

    assert_raises(RuntimeError) do
      @importer.call(instrument: @instrument, from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26))
    end

    assert_empty DailyClosingPrice.where(instrument: @instrument)
    assert_equal 0, state.reload.source_generation
  ensure
    Performance::ObservationInvalidator.define_singleton_method(:mark!, original)
  end

  test "rejects an inverted date range" do
    assert_raises(ArgumentError) do
      @importer.call(instrument: @instrument, from: Date.new(2026, 8, 26), to: Date.new(2026, 8, 24))
    end
  end

  test "builds the default Yahoo provider" do
    assert_instance_of DailyClosingPrice::Providers::YahooFinance, DailyClosingPrice::Importer.default.send(:provider)
  end

  test "rejects observations from another instrument or provider" do
    provider = Object.new
    provider.define_singleton_method(:identifier) { "fake_provider" }
    provider.define_singleton_method(:fetch) do |instrument:, **|
      [ DailyClosingPrice::Observation.new(
        instrument:, trading_date: Date.current, close_price: BigDecimal("10"),
        currency: "EUR", provider: "other_provider", observed_at: Time.current
      ) ]
    end

    assert_raises(ArgumentError) do
      DailyClosingPrice::Importer.new(provider:).call(instrument: @instrument, from: Date.current, to: Date.current)
    end
  end

  private

  class FakeProvider
    attr_accessor :price

    def initialize
      @price = BigDecimal("500.12345678")
    end

    def identifier = "fake_provider"

    def fetch(instrument:, from:, to:)
      [ from, to ].filter_map do |date|
        next unless date.wday == 1 || date.wday == 3

        DailyClosingPrice::Observation.new(
          instrument:, trading_date: date, close_price: price,
          currency: instrument.currency, provider: identifier, observed_at: date.to_time
        )
      end
    end
  end
end
