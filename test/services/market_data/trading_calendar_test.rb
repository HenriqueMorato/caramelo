require "test_helper"

class TradingCalendarTest < ActiveSupport::TestCase
  test "returns the previous Friday for a Monday" do
    assert_equal Date.new(2026, 8, 28), described_class.previous_business_day(Date.new(2026, 8, 31))
  end

  test "returns the previous weekday for a weekday" do
    assert_equal Date.new(2026, 8, 27), described_class.previous_business_day(Date.new(2026, 8, 28))
  end

  test "returns only weekdays in a range" do
    dates = described_class.weekdays_between(Date.new(2026, 8, 28), Date.new(2026, 8, 31))

    assert_equal [ Date.new(2026, 8, 28), Date.new(2026, 8, 31) ], dates
  end

  test "identifies weekends" do
    assert described_class.weekend?(Date.new(2026, 8, 29))
    refute described_class.weekend?(Date.new(2026, 8, 28))
  end

  private

  def described_class
    TradingCalendar
  end
end
