require "test_helper"

class MarketData::YahooFinance::FxClientTest < ActiveSupport::TestCase
  test "parses an intraday currency pair quote" do
    transport = FakeTransport.new(response: response)
    client = MarketData::YahooFinance::FxClient.new(transport:)

    rate = client.rate(base_currency: "USD", quote_currency: "BRL")

    assert_equal BigDecimal("5.1234"), rate.rate
    assert_equal Time.at(1_777_000_000).utc, rate.observed_at
    assert_equal "/v8/finance/chart/USDBRL=X", transport.uri.path
  end

  test "rejects a quote whose currency does not match the requested quote" do
    transport = FakeTransport.new(response: response(currency: "USD"))
    client = MarketData::YahooFinance::FxClient.new(transport:)

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.rate(base_currency: "USD", quote_currency: "BRL")
    end
  end

  test "rejects a non-success response" do
    client = MarketData::YahooFinance::FxClient.new(
      transport: FakeTransport.new(response: MarketData::YahooFinance::Response.new(status: 429, body: "", headers: {}))
    )

    assert_raises(MarketData::YahooFinance::Error) { client.rate(base_currency: "USD", quote_currency: "BRL") }
  end

  test "rejects malformed response data" do
    client = MarketData::YahooFinance::FxClient.new(
      transport: FakeTransport.new(response: MarketData::YahooFinance::Response.new(status: 200, body: "{}", headers: {}))
    )

    assert_raises(MarketData::YahooFinance::InvalidResponse) { client.rate(base_currency: "USD", quote_currency: "BRL") }
  end

  test "rejects a response without exactly one result" do
    body = { chart: { result: [], error: nil } }.to_json
    client = MarketData::YahooFinance::FxClient.new(
      transport: FakeTransport.new(response: MarketData::YahooFinance::Response.new(status: 200, body:, headers: {}))
    )

    assert_raises(MarketData::YahooFinance::InvalidResponse) { client.rate(base_currency: "USD", quote_currency: "BRL") }
  end

  test "rejects a non-positive FX rate" do
    client = MarketData::YahooFinance::FxClient.new(transport: FakeTransport.new(response: response(price: "0")))

    assert_raises(MarketData::YahooFinance::InvalidResponse) { client.rate(base_currency: "USD", quote_currency: "BRL") }
  end

  private

  FakeTransport = Struct.new(:response, :uri) do
    def get(uri)
      self.uri = uri
      response
    end
  end

  def response(currency: "BRL", price: "5.1234")
    MarketData::YahooFinance::Response.new(
      status: 200,
      body: {
        chart: {
          result: [ { meta: { regularMarketPrice: BigDecimal(price), currency:, regularMarketTime: 1_777_000_000 } } ],
          error: nil
        }
      }.to_json,
      headers: {}
    )
  end
end
