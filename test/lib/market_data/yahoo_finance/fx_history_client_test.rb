require "test_helper"

class MarketData::YahooFinance::FxHistoryClientTest < ActiveSupport::TestCase
  test "parses dated FX closes and skips missing dates" do
    transport = FakeTransport.new(response: response)
    rates = client_with(response, transport:).daily_rates(base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26))

    assert_equal [ BigDecimal("5.432109876543"), BigDecimal("5.5") ], rates.map(&:rate)
    assert_equal [ Date.new(2026, 8, 24), Date.new(2026, 8, 26) ], rates.map(&:rate_date)
    assert_equal "USDBRL=X", transport.uri.path.split("/").last
  end

  test "rejects inverted and future ranges" do
    assert_raises(ArgumentError) { client.daily_rates(base_currency: "USD", quote_currency: "BRL", from: Date.current, to: Date.current - 1) }
    assert_raises(ArgumentError) { client.daily_rates(base_currency: "USD", quote_currency: "BRL", from: Date.current, to: Date.current + 1) }
  end

  test "rejects malformed quote data and invalid currency" do
    malformed = response(result: default_result.merge(indicators: { quote: [] }))
    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client_with(malformed).daily_rates(base_currency: "USD", quote_currency: "BRL", from: Date.current, to: Date.current)
    end
  end

  test "rejects malformed result, timestamps, and closes" do
    [ nil, default_result.merge(timestamp: {}), default_result.merge(indicators: { quote: [ { close: {} } ] }) ].each do |result|
      error = assert_raises(MarketData::YahooFinance::InvalidResponse) do
        client_with(response(result:)).daily_rates(base_currency: "USD", quote_currency: "BRL", from: Date.current, to: Date.current)
      end
      assert_match(/malformed|timestamps|closes|exactly one/, error.message)
    end
  end

  test "reports provider chart errors clearly" do
    error = assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client_with(response(result: default_result, error: { "code" => "Bad Request", "description" => "Invalid range" })).daily_rates(
        base_currency: "USD", quote_currency: "BRL", from: Date.current, to: Date.current
      )
    end

    assert_equal "Invalid range", error.message
  end

  test "rejects invalid FX rates" do
    malformed = default_result.merge(indicators: { quote: [ { close: [ "not-a-rate", nil, BigDecimal("5.5") ] } ] })

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client_with(response(result: malformed)).daily_rates(base_currency: "USD", quote_currency: "BRL", from: Date.current, to: Date.current)
    end
  end

  test "rejects invalid timestamps" do
    malformed = default_result.merge(timestamp: [ "not-a-timestamp", nil, nil ])

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client_with(response(result: malformed)).daily_rates(base_currency: "USD", quote_currency: "BRL", from: Date.current, to: Date.current)
    end
  end

  test "derives the rate date from the UTC candle timestamp" do
    result = default_result.merge(
      timestamp: [ Time.utc(2026, 8, 24, 23, 59, 59).to_i ],
      indicators: { quote: [ { close: [ BigDecimal("5.4321") ] } ] }
    )

    rates = client_with(response(result:)).daily_rates(
      base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24)
    )

    assert_equal Date.new(2026, 8, 24), rates.first.rate_date
  end

  private

  FakeTransport = Struct.new(:response, :uri) do
    def get(uri)
      self.uri = uri
      response
    end
  end

  def client
    @client ||= MarketData::YahooFinance::FxHistoryClient.new(transport: FakeTransport.new(response: response))
  end

  def client_with(response, transport: FakeTransport.new(response:))
    MarketData::YahooFinance::FxHistoryClient.new(transport:)
  end

  def response(result: default_result, error: nil)
    MarketData::YahooFinance::Response.new(status: 200, body: { chart: { result: [ result ], error: } }.to_json, headers: {})
  end

  def default_result
    {
      meta: { symbol: "USDBRL=X", currency: "BRL" },
      timestamp: [ Time.utc(2026, 8, 24, 21).to_i, Time.utc(2026, 8, 25, 21).to_i, Time.utc(2026, 8, 26, 21).to_i ],
      indicators: { quote: [ { close: [ BigDecimal("5.432109876543"), nil, BigDecimal("5.5") ] } ] }
    }
  end
end
