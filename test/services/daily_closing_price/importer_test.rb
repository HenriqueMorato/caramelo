require "test_helper"

class DailyClosingPrice::ImporterTest < ActiveSupport::TestCase
  setup do
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
