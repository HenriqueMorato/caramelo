require "test_helper"

class MarketData::YahooFinance::IdentifierTest < ActiveSupport::TestCase
  test "builds a normalized Yahoo identifier for a B3 listing" do
    identifier = MarketData::YahooFinance::Identifier.build(ticker: " petr4 ", mic: " bvmf ")

    assert_equal "PETR4.SA", identifier.value
    assert_predicate identifier, :frozen?
  end

  test "rejects unsupported exchanges and malformed tickers" do
    assert_raises(MarketData::YahooFinance::UnsupportedExchange) do
      MarketData::YahooFinance::Identifier.build(ticker: "AAPL", mic: "XNAS")
    end

    assert_raises(MarketData::YahooFinance::InvalidIdentifier) do
      MarketData::YahooFinance::Identifier.build(ticker: "PETR4.SA/../../", mic: "BVMF")
    end
  end
end
