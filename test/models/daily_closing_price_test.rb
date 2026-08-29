require "test_helper"

class DailyClosingPriceTest < ActiveSupport::TestCase
  test "requires a matching instrument currency" do
    record = DailyClosingPrice.new(
      instrument: instruments(:voo_arcx), trading_date: Date.current,
      close_price: BigDecimal("123.45678901"), currency: "BRL",
      provider: "yahoo_finance", observed_at: Time.current
    )

    assert_not record.valid?
    assert_includes record.errors[:currency], "is invalid"
  end

  test "stores a precise daily close" do
    record = DailyClosingPrice.create!(
      instrument: instruments(:voo_arcx), trading_date: Date.new(2026, 8, 28),
      close_price: BigDecimal("123.45678901"), currency: "USD",
      provider: "yahoo_finance", observed_at: Time.utc(2026, 8, 28, 20)
    )

    assert_equal BigDecimal("123.45678901"), record.reload.close_price
    assert_equal "USD", record.currency
  end

  test "enforces one observation per instrument date and provider" do
    attributes = {
      instrument: instruments(:voo_arcx), trading_date: Date.new(2026, 8, 27),
      close_price: BigDecimal("123"), currency: "USD",
      provider: "yahoo_finance", observed_at: Time.current
    }
    DailyClosingPrice.create!(attributes)

    duplicate = DailyClosingPrice.new(attributes)

    assert_not duplicate.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "prevents deleting an instrument with daily history" do
    instrument = Instrument.create!(ticker: "HIST", exchange: "XNAS", name: "History ETF", currency: "USD")
    DailyClosingPrice.create!(
      instrument:, trading_date: Date.current, close_price: BigDecimal("10"), currency: "USD",
      provider: "yahoo_finance", observed_at: Time.current
    )

    assert_not instrument.destroy
    assert_predicate instrument.errors[:base], :any?
  end
end
