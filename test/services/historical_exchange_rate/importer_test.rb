require "test_helper"

class HistoricalExchangeRate::ImporterTest < ActiveSupport::TestCase
  setup do
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

  private

  class FakeProvider
    attr_accessor :rate
    attr_reader :requested_pair
    attr_accessor :include_out_of_range

    def initialize
      @rate = BigDecimal("5")
      @include_out_of_range = false
    end

    def identifier = "test_provider"

    def fetch(base_currency:, quote_currency:, from:, to:)
      @requested_pair = [ base_currency, quote_currency ]
      dates = [ from, to ].uniq
      dates << from + 2 if include_out_of_range
      dates.filter_map do |date|
        next unless date.wday == 1 || date.wday == 3

        HistoricalExchangeRate::Observation.new(
          base_currency:, quote_currency:, rate_date: date, rate:, provider: identifier,
          observed_at: date.to_time, fetched_at: Time.current
        )
      end
    end
  end
end
