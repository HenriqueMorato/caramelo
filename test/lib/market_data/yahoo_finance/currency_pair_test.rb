require "test_helper"

class MarketData::YahooFinance::CurrencyPairTest < ActiveSupport::TestCase
  test "normalizes currencies and builds Yahoo symbol" do
    pair = MarketData::YahooFinance::CurrencyPair.new(base_currency: " usd ", quote_currency: "brl")

    assert_equal "USD", pair.base_currency
    assert_equal "BRL", pair.quote_currency
    assert_equal "USDBRL=X", pair.symbol
  end

  test "rejects invalid and same currencies" do
    assert_raises(ArgumentError) do
      MarketData::YahooFinance::CurrencyPair.new(base_currency: "US", quote_currency: "BRL")
    end

    assert_raises(ArgumentError) do
      MarketData::YahooFinance::CurrencyPair.new(base_currency: "USD", quote_currency: "USD")
    end
  end
end
