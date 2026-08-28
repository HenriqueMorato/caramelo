require "test_helper"

class MarketData::YahooFinance::IdentifierTest < ActiveSupport::TestCase
  test "maps supported listing MICs to explicit Yahoo identifiers" do
    {
      [ " petr4 ", " bvmf " ] => "PETR4.SA",
      [ " aapl ", " xnas " ] => "AAPL",
      [ " ibm ", " xnys " ] => "IBM",
      [ " voo ", " arcx " ] => "VOO"
    }.each do |(ticker, mic), expected_value|
      identifier = MarketData::YahooFinance::Identifier.build(ticker:, mic:)

      assert_equal expected_value, identifier.value
      assert_predicate identifier, :frozen?
    end
  end

  test "normalizes a US share-class separator for Yahoo" do
    identifier = MarketData::YahooFinance::Identifier.build(ticker: "BRK.B", mic: "XNYS")

    assert_equal "BRK-B", identifier.value
  end

  test "matches only provider venues and instrument types allowed for the listing" do
    nasdaq = MarketData::YahooFinance::Identifier.build(ticker: "AAPL", mic: "XNAS")

    assert nasdaq.matches_provider_exchange?("NMS")
    assert nasdaq.matches_provider_exchange?("NGM")
    assert_not nasdaq.matches_provider_exchange?("NYQ")
    assert nasdaq.supports_instrument_type?("EQUITY")
    assert nasdaq.supports_instrument_type?("ETF")
    assert_not nasdaq.supports_instrument_type?("MUTUALFUND")
  end

  test "rejects unsupported exchanges and malformed tickers" do
    assert_raises(MarketData::YahooFinance::UnsupportedExchange) do
      MarketData::YahooFinance::Identifier.build(ticker: "VWRA", mic: "XLON")
    end

    assert_raises(MarketData::YahooFinance::InvalidIdentifier) do
      MarketData::YahooFinance::Identifier.build(ticker: "PETR4.SA/../../", mic: "BVMF")
    end

    assert_raises(MarketData::YahooFinance::InvalidIdentifier) do
      MarketData::YahooFinance::Identifier.build(ticker: "BAD/SYMBOL", mic: "XNAS")
    end
  end
end
