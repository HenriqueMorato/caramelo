require "test_helper"

class MarketData::YahooFinance::QuoteClientTest < ActiveSupport::TestCase
  setup do
    @identifier = MarketData::YahooFinance::Identifier.build(ticker: "PETR4", mic: "BVMF")
  end

  test "returns a precise quote from chart metadata" do
    client = build_client(body: chart_body(price: "32.45678901"))

    quote = client.quote(@identifier)

    assert_equal "PETR4.SA", quote.symbol
    assert_equal BigDecimal("32.45678901"), quote.unit_price
    assert_equal "BRL", quote.currency
    assert_equal Time.at(1_777_000_000).utc, quote.quoted_at
    assert_equal "SAO", quote.provider_exchange
    assert_equal "EQUITY", quote.instrument_type
    assert_equal "BRL", quote.provider_currency
    assert_predicate quote.quoted_at, :utc?
  end

  test "accepts matching London, Xetra, Amsterdam, and Paris ETF venues" do
    {
      [ "VWRA", "XLON" ] => [ "VWRA.L", "LSE", "USD" ],
      [ "VWCE", "XETR" ] => [ "VWCE.DE", "GER", "EUR" ],
      [ "IWDA", "XAMS" ] => [ "IWDA.AS", "AMS", "EUR" ],
      [ "CW8", "XPAR" ] => [ "CW8.PA", "PAR", "EUR" ]
    }.each do |(ticker, mic), (symbol, provider_exchange, currency)|
      identifier = MarketData::YahooFinance::Identifier.build(ticker:, mic:)
      quote = build_client(
        body: chart_body(symbol:, currency:, provider_exchange:, instrument_type: "ETF")
      ).quote(identifier)

      assert_equal symbol, quote.symbol
      assert_equal provider_exchange, quote.provider_exchange
      assert_equal currency, quote.currency
      assert_equal "ETF", quote.instrument_type
    end
  end

  test "normalizes Yahoo pence denominations to pounds without losing the provider value" do
    identifier = MarketData::YahooFinance::Identifier.build(ticker: "IUSA", mic: "XLON")

    %w[GBp GBX].each do |provider_currency|
      quote = build_client(
        body: chart_body(
          symbol: "IUSA.L",
          price: "5707.25",
          currency: provider_currency,
          provider_exchange: "LSE",
          instrument_type: "ETF"
        )
      ).quote(identifier)

      assert_equal BigDecimal("57.0725"), quote.unit_price
      assert_equal "GBP", quote.currency
      assert_equal provider_currency, quote.provider_currency
    end
  end

  test "preserves a Yahoo pound quote without pence conversion" do
    identifier = MarketData::YahooFinance::Identifier.build(ticker: "VWRP", mic: "XLON")

    quote = build_client(
      body: chart_body(
        symbol: "VWRP.L",
        price: "144.22",
        currency: "GBP",
        provider_exchange: "LSE",
        instrument_type: "ETF"
      )
    ).quote(identifier)

    assert_equal BigDecimal("144.22"), quote.unit_price
    assert_equal "GBP", quote.currency
    assert_equal "GBP", quote.provider_currency
  end

  test "rejects an equity response for a UCITS ETF venue" do
    identifier = MarketData::YahooFinance::Identifier.build(ticker: "VOD", mic: "XLON")

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      build_client(
        body: chart_body(symbol: "VOD.L", currency: "GBP", provider_exchange: "LSE", instrument_type: "EQUITY")
      ).quote(identifier)
    end
  end

  test "normalizes an integer JSON price to BigDecimal" do
    quote = build_client(body: chart_body(price: 32)).quote(@identifier)

    assert_instance_of BigDecimal, quote.unit_price
    assert_equal BigDecimal("32"), quote.unit_price
  end

  test "requests the direct one-day chart endpoint without a crumb" do
    transport = FakeTransport.new(response: response(body: chart_body))

    MarketData::YahooFinance::QuoteClient.new(transport:).quote(@identifier)

    assert_equal 1, transport.uris.size
    assert_equal "query1.finance.yahoo.com", transport.uris.first.host
    assert_equal "/v8/finance/chart/PETR4.SA", transport.uris.first.path
    assert_equal({ "range" => "1d", "interval" => "1d" }, URI.decode_www_form(transport.uris.first.query).to_h)
    assert_not_includes transport.uris.first.query, "crumb"
  end

  test "accepts matching NASDAQ, NYSE, and NYSE Arca response venues" do
    {
      [ "AAPL", "XNAS" ] => [ "NMS", "EQUITY" ],
      [ "IBM", "XNYS" ] => [ "NYQ", "EQUITY" ],
      [ "VOO", "ARCX" ] => [ "PCX", "ETF" ]
    }.each do |(ticker, mic), (provider_exchange, instrument_type)|
      identifier = MarketData::YahooFinance::Identifier.build(ticker:, mic:)
      quote = build_client(
        body: chart_body(
          symbol: ticker,
          currency: "USD",
          provider_exchange:,
          instrument_type:
        )
      ).quote(identifier)

      assert_equal ticker, quote.symbol
      assert_equal provider_exchange, quote.provider_exchange
      assert_equal instrument_type, quote.instrument_type
    end
  end

  test "classifies HTTP failures" do
    {
      401 => MarketData::YahooFinance::Unauthorized,
      403 => MarketData::YahooFinance::Unauthorized,
      404 => MarketData::YahooFinance::SymbolNotFound,
      429 => MarketData::YahooFinance::RateLimited,
      500 => MarketData::YahooFinance::ProviderUnavailable,
      418 => MarketData::YahooFinance::HTTPError
    }.each do |status, error_class|
      error = assert_raises(error_class) do
        build_client(status:, headers: { "retry-after" => "60" }).quote(@identifier)
      end

      assert_equal status, error.status
      assert_equal "60", error.retry_after if error.is_a?(MarketData::YahooFinance::RateLimited)
    end
  end

  test "maps a successful Yahoo missing-symbol payload" do
    body = JSON.generate(
      chart: {
        result: nil,
        error: { code: "Not Found", description: "No data found, symbol may be delisted" }
      }
    )

    error = assert_raises(MarketData::YahooFinance::SymbolNotFound) do
      build_client(body:).quote(@identifier)
    end

    assert_equal "No data found, symbol may be delisted", error.message
  end

  test "maps a non-symbol chart error to an invalid response" do
    body = JSON.generate(chart: { result: nil, error: "temporarily unavailable" })

    error = assert_raises(MarketData::YahooFinance::InvalidResponse) do
      build_client(body:).quote(@identifier)
    end

    assert_equal "temporarily unavailable", error.message
  end

  test "rejects a float before decimal conversion" do
    error = assert_raises(MarketData::YahooFinance::InvalidResponse) do
      build_client.send(:normalize_price, 1.25)
    end

    assert_equal "price must not be a float", error.message
  end

  test "rejects malformed and inconsistent responses" do
    invalid_bodies = [
      "not json",
      JSON.generate(chart: { result: [], error: nil }),
      chart_body(symbol: "VALE3.SA"),
      chart_body(price: 0),
      chart_body(price: -1),
      chart_body(price: '"not-a-price"'),
      chart_body(currency: "Brazilian real"),
      chart_body(quoted_at: "not-a-time"),
      chart_body(provider_exchange: "NYQ"),
      chart_body(instrument_type: "MUTUALFUND")
    ]

    invalid_bodies.each do |body|
      assert_raises(MarketData::YahooFinance::InvalidResponse) do
        build_client(body:).quote(@identifier)
      end
    end
  end

  private

  FakeTransport = Data.define(:response, :uris) do
    def initialize(response:, uris: [])
      super(response:, uris:)
    end

    def get(uri)
      uris << uri
      response
    end
  end

  def build_client(status: 200, body: chart_body, headers: {})
    MarketData::YahooFinance::QuoteClient.new(
      transport: FakeTransport.new(response: response(status:, body:, headers:))
    )
  end

  def response(status: 200, body: "", headers: {})
    MarketData::YahooFinance::Response.new(status:, body:, headers:)
  end

  def chart_body(symbol: "PETR4.SA", price: "32.45", currency: "BRL", quoted_at: 1_777_000_000,
    provider_exchange: "SAO", instrument_type: "EQUITY")
    price_json = price.is_a?(String) ? price : price.to_json
    <<~JSON
      {
        "chart": {
          "result": [{
            "meta": {
              "symbol": #{symbol.to_json},
              "regularMarketPrice": #{price_json},
              "currency": #{currency.to_json},
              "regularMarketTime": #{quoted_at.to_json},
              "exchangeName": #{provider_exchange.to_json},
              "instrumentType": #{instrument_type.to_json}
            }
          }],
          "error": null
        }
      }
    JSON
  end
end
