require "test_helper"

class MarketData::YahooFinance::FxHistoryClientTest < ActiveSupport::TestCase
  test "parses dated FX closes and skips missing dates" do
    transport = FakeTransport.new(response: response)
    rates = client_with(response, transport:).daily_rates(base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26))

    assert_equal [ BigDecimal("5.432109876543"), BigDecimal("5.5") ], rates.map(&:rate)
    assert_equal [ Date.new(2026, 8, 24), Date.new(2026, 8, 26) ], rates.map(&:rate_date)
    assert_equal "USDBRL%3DX", transport.uri.path.split("/").last
  end

  test "requests past the weekend label for a Friday range" do
    transport = FakeTransport.new(response: response)

    client_with(response, transport:).daily_rates(
      base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 28), to: Date.new(2026, 8, 28)
    )

    query = URI.decode_www_form(transport.uri.query).to_h
    assert_equal Time.zone.local(2026, 8, 31).to_i.to_s, query.fetch("period2")
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

  test "rejects a non-hash parsed result" do
    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.send(
        :parse_rates, nil, base_currency: "USD", quote_currency: "BRL",
        from: Date.current, to: Date.current
      )
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
      client_with(response(result: malformed)).daily_rates(
        base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26)
      )
    end
  end

  test "rejects invalid timestamps" do
    malformed = default_result.merge(timestamp: [ "not-a-timestamp", nil, nil ])

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client_with(response(result: malformed)).daily_rates(base_currency: "USD", quote_currency: "BRL", from: Date.current, to: Date.current)
    end
  end

  test "derives the rate date from a weekday UTC candle timestamp" do
    result = default_result.merge(
      timestamp: [ Time.utc(2026, 8, 24, 23, 59, 59).to_i ],
      indicators: { quote: [ { close: [ BigDecimal("5.4321") ] } ] }
    )

    rates = client_with(response(result:)).daily_rates(
      base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24)
    )

    assert_equal Date.new(2026, 8, 24), rates.first.rate_date
  end

  test "maps weekend FX candle timestamps to the preceding business day" do
    result = default_result.merge(
      timestamp: [ Time.utc(2026, 8, 30, 23).to_i ],
      indicators: { quote: [ { close: [ BigDecimal("5.4321") ] } ] }
    )

    rates = client_with(response(result:)).daily_rates(
      base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 28), to: Date.new(2026, 8, 28)
    )

    assert_equal Date.new(2026, 8, 28), rates.first.rate_date
  end

  test "prefers the weekday close when a live weekend quote normalizes to the same date" do
    result = default_result.merge(
      timestamp: [ Time.utc(2026, 11, 13).to_i, Time.utc(2026, 11, 15, 17, 18, 1).to_i ],
      indicators: { quote: [ { close: [ BigDecimal("5.64"), BigDecimal("5.66") ] } ] }
    )

    rates = client_with(response(result:)).daily_rates(
      base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 11, 13), to: Date.new(2026, 11, 13)
    )

    assert_equal [ BigDecimal("5.64") ], rates.map(&:rate)
  end

  test "rejects conflicting weekday closes for one date" do
    result = default_result.merge(
      timestamp: [ Time.utc(2026, 11, 13).to_i, Time.utc(2026, 11, 13, 21).to_i ],
      indicators: { quote: [ { close: [ BigDecimal("5.64"), BigDecimal("5.8") ] } ] }
    )

    error = assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client_with(response(result:)).daily_rates(
        base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 11, 13), to: Date.new(2026, 11, 13)
      )
    end

    assert_equal "FX history contains duplicate weekday dates", error.message
  end

  test "discards boundary candles outside the requested date range" do
    result = default_result.merge(
      timestamp: [ Time.utc(2026, 8, 23, 21).to_i, Time.utc(2026, 8, 24, 21).to_i, Time.utc(2026, 8, 25, 21).to_i ],
      indicators: { quote: [ { close: [ BigDecimal("5.4"), BigDecimal("5.5"), BigDecimal("5.6") ] } ] }
    )

    rates = client_with(response(result:)).daily_rates(
      base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24)
    )

    assert_equal [ Date.new(2026, 8, 24) ], rates.map(&:rate_date)
    assert_equal [ BigDecimal("5.5") ], rates.map(&:rate)
  end

  test "rejects same-currency and invalid currency requests" do
    assert_raises(ArgumentError) do
      client.daily_rates(base_currency: "USD", quote_currency: "USD", from: Date.current, to: Date.current)
    end
    assert_raises(ArgumentError) do
      client.daily_rates(base_currency: "XXX", quote_currency: "BRL", from: Date.current, to: Date.current)
    end
  end

  test "rejects mismatched symbols, currencies, and array lengths" do
    cases = [
      default_result.merge(meta: default_result[:meta].merge(symbol: "EURBRL=X")),
      default_result.merge(meta: default_result[:meta].merge(currency: "USD")),
      default_result.merge(timestamp: [ 1, 2 ])
    ]

    cases.each do |result|
      assert_raises(MarketData::YahooFinance::InvalidResponse) do
        client_with(response(result:)).daily_rates(base_currency: "USD", quote_currency: "BRL", from: Date.current, to: Date.current)
      end
    end
  end

  test "retries a transient mismatched symbol response" do
    mismatched = response(result: default_result.merge(meta: default_result[:meta].merge(symbol: "EURBRL=X")))
    transport = FakeTransport.new(response: mismatched, responses: [ mismatched, response ])

    rates = client_with(response, transport:).daily_rates(
      base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 24)
    )

    assert_equal [ Date.new(2026, 8, 24) ], rates.map(&:rate_date)
    assert_equal 2, transport.calls
  end

  test "rejects float and non-positive historical rates" do
    assert_raises(MarketData::YahooFinance::InvalidResponse) { client.send(:normalize_rate, 1.2) }

    result = default_result.merge(indicators: { quote: [ { close: [ "0", nil, BigDecimal("5.5") ] } ] })
    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client_with(response(result:)).daily_rates(
        base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26)
      )
    end
  end

  test "reports a scalar provider chart error" do
    error = assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client_with(response(result: default_result, error: "Bad Request")).daily_rates(
        base_currency: "USD", quote_currency: "BRL", from: Date.current, to: Date.current
      )
    end

    assert_equal "Bad Request", error.message
  end

  private

  FakeTransport = Struct.new(:response, :uri, :responses, :calls) do
    def get(uri)
      self.uri = uri
      self.calls = calls.to_i + 1
      responses&.shift || response
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
