require "test_helper"

class MarketData::TargetTest < ActiveSupport::TestCase
  test "normalizes a target and builds a stable scope" do
    target = MarketData::Target.new(
      kind: "historical_exchange_rates",
      record_id: 4,
      base_currency: " usd ",
      quote_currency: "brl",
      provider: " Yahoo_Finance_FX "
    )

    assert_equal :historical_exchange_rates, target.kind
    assert_equal "USD", target.base_currency
    assert_equal "BRL", target.quote_currency
    assert_equal "yahoo_finance_fx", target.provider
    assert_equal "market_data_health:historical_exchange_rates:4:USD:BRL:yahoo_finance_fx", target.scope
  end

  test "rejects unsupported target kinds" do
    error = assert_raises(ArgumentError) do
      MarketData::Target.new(kind: :unknown)
    end

    assert_equal "unsupported market data target", error.message
  end

  test "uses a shared publication scope for inverse currency pairs" do
    direct = MarketData::Target.new(kind: :historical_exchange_rates, base_currency: "USD", quote_currency: "BRL")
    inverse = MarketData::Target.new(kind: :historical_exchange_rates, base_currency: "BRL", quote_currency: "USD")

    assert_equal direct.publication_scope, inverse.publication_scope
  end
end
