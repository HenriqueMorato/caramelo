require "test_helper"

class CurrentMarketPriceTest < ActiveSupport::TestCase
  test "preserves a precise sub-cent unit price through the cache payload" do
    current_market_price = build_current_market_price(unit_price: "0.00490000")

    restored_current_market_price = CurrentMarketPrice.from_cache_payload(current_market_price.to_cache_payload)

    assert_equal BigDecimal("0.0049"), restored_current_market_price.unit_price
    assert_equal "USD", restored_current_market_price.currency
    assert_equal "example", restored_current_market_price.provider
    assert_equal current_market_price.quoted_at, restored_current_market_price.quoted_at
    assert_equal current_market_price.fetched_at, restored_current_market_price.fetched_at
  end

  test "rounds only after multiplying precise price and quantity" do
    current_market_price = build_current_market_price(unit_price: "0.0049")

    assert_equal Money.from_cents(1, "USD"), current_market_price.valuation_for(2)
  end

  test "normalizes currency provider and timestamps" do
    zoned_time = Time.find_zone!("America/Sao_Paulo").parse("2026-08-25 10:00:00")
    current_market_price = build_current_market_price(
      currency: " usd ",
      provider: " EXAMPLE ",
      quoted_at: zoned_time,
      fetched_at: zoned_time
    )

    assert_equal "USD", current_market_price.currency
    assert_equal "example", current_market_price.provider
    assert_equal zoned_time.utc, current_market_price.quoted_at
    assert_equal zoned_time.utc, current_market_price.fetched_at
  end

  test "rejects floats and invalid financial values" do
    assert_raises(CurrentMarketPrice::InvalidValue) { build_current_market_price(unit_price: 1.23) }
    assert_raises(CurrentMarketPrice::InvalidValue) { build_current_market_price(unit_price: "0") }
    assert_raises(CurrentMarketPrice::InvalidValue) { build_current_market_price(unit_price: "Infinity") }
    assert_raises(CurrentMarketPrice::InvalidValue) { build_current_market_price(currency: "ZZZ") }
    assert_raises(CurrentMarketPrice::InvalidValue) { build_current_market_price(currency: "840") }
    assert_raises(CurrentMarketPrice::InvalidValue) { build_current_market_price(provider: "bad provider") }
    assert_raises(CurrentMarketPrice::InvalidValue) { build_current_market_price(quoted_at: nil) }
  end

  test "rejects invalid quantities without accepting floats" do
    current_market_price = build_current_market_price

    assert_raises(CurrentMarketPrice::InvalidValue) { current_market_price.valuation_for(-1) }
    assert_raises(CurrentMarketPrice::InvalidValue) { current_market_price.valuation_for(1.5) }
  end

  private

  def build_current_market_price(unit_price: "12.3456", currency: "USD", provider: "example",
    quoted_at: Time.utc(2026, 8, 25, 12), fetched_at: Time.utc(2026, 8, 25, 12, 0, 5))
    CurrentMarketPrice.new(unit_price:, currency:, provider:, quoted_at:, fetched_at:)
  end
end
