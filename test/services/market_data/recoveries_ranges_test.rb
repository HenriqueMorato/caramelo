require "test_helper"

class MarketDataRecoveriesRangesTest < ActiveSupport::TestCase
  DEFAULT_DATE = Date.new(2026, 8, 28)
  EXPLICIT_RANGE = Date.new(2026, 8, 1)..Date.new(2026, 8, 3)

  setup do
    @calendar = TradingCalendar
    @previous_business_day = @calendar.method(:previous_business_day)
    @calendar.define_singleton_method(:previous_business_day) { DEFAULT_DATE }
  end

  teardown do
    @calendar.define_singleton_method(:previous_business_day, @previous_business_day)
  end

  test "normalizes daily closing price ranges" do
    assert_equal [ DEFAULT_DATE, DEFAULT_DATE ], normalize(MarketData::Recoveries::DailyClosingPrices)
    assert_equal [ EXPLICIT_RANGE.begin, EXPLICIT_RANGE.end ], normalize(
      MarketData::Recoveries::DailyClosingPrices, EXPLICIT_RANGE
    )
    assert_invalid(MarketData::Recoveries::DailyClosingPrices)
  end

  test "normalizes historical exchange rate ranges" do
    assert_equal [ DEFAULT_DATE, DEFAULT_DATE ], normalize(MarketData::Recoveries::HistoricalExchangeRates)
    assert_equal [ EXPLICIT_RANGE.begin, EXPLICIT_RANGE.end ], normalize(
      MarketData::Recoveries::HistoricalExchangeRates, EXPLICIT_RANGE
    )
    assert_invalid(MarketData::Recoveries::HistoricalExchangeRates)
  end

  test "normalizes benchmark observation ranges" do
    assert_equal [ DEFAULT_DATE, DEFAULT_DATE ], normalize(MarketData::Recoveries::BenchmarkObservations)
    assert_equal [ EXPLICIT_RANGE.begin, EXPLICIT_RANGE.end ], normalize(
      MarketData::Recoveries::BenchmarkObservations, EXPLICIT_RANGE
    )
    assert_invalid(MarketData::Recoveries::BenchmarkObservations)
  end

  private

  def normalize(service, range = nil)
    service.send(:normalized_range, range)
  end

  def assert_invalid(service)
    assert_raises(ArgumentError) { normalize(service, "2026-08-01".."2026-08-03") }
  end
end
