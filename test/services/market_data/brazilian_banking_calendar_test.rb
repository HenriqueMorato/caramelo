require "test_helper"

class MarketData::BrazilianBankingCalendarTest < ActiveSupport::TestCase
  test "identifies fixed and movable Brazilian banking holidays" do
    holidays = [
      Date.new(2025, 11, 20), Date.new(2025, 12, 25), Date.new(2026, 1, 1),
      Date.new(2026, 2, 16), Date.new(2026, 2, 17), Date.new(2026, 4, 3),
      Date.new(2026, 4, 21), Date.new(2026, 5, 1), Date.new(2026, 6, 4), Date.new(2026, 9, 7)
    ]

    assert holidays.all? { |date| described_class.holiday?(date) }
    assert_equal Date.new(2026, 4, 5), described_class.easter_sunday(2026)
  end

  test "keeps ordinary unpublished weekdays required" do
    from = Date.new(2026, 9, 7)
    to = Date.new(2026, 9, 12)

    assert_equal (Date.new(2026, 9, 8)..Date.new(2026, 9, 11)).to_a,
      described_class.business_days_between(from, to)
    refute described_class.holiday?(Date.new(2026, 9, 11))
  end

  private

  def described_class
    MarketData::BrazilianBankingCalendar
  end
end
