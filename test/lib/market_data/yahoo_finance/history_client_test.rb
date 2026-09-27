require "test_helper"

class MarketData::YahooFinance::HistoryClientTest < ActiveSupport::TestCase
  test "parses daily close observations and omits missing closes" do
    identifier = MarketData::YahooFinance::Identifier.build(ticker: "VOO", mic: "ARCX")
    transport = FakeTransport.new(response: response)

    closes = MarketData::YahooFinance::HistoryClient.new(transport:).daily_closes(
      identifier:, from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26)
    )

    assert_equal [ BigDecimal("500.12345678"), BigDecimal("501.25") ], closes.map(&:close_price)
    assert_equal [ Date.new(2026, 8, 24), Date.new(2026, 8, 26) ], closes.map(&:trading_date)
    assert_equal "/v8/finance/chart/VOO", transport.uri.path
    assert_includes transport.uri.query, "interval=1d"
    query = URI.decode_www_form(transport.uri.query).to_h
    assert_equal Time.zone.local(2026, 8, 24).to_i.to_s, query.fetch("period1")
    assert_equal Time.zone.local(2026, 8, 27).to_i.to_s, query.fetch("period2")
  end

  test "parses dividends and splits while preserving the bounded event payload" do
    result = default_result.merge(
      events: {
        dividends: {
          "1787851200" => { "amount" => BigDecimal("0.25"), "date" => 1787851200, "type" => "DIVIDEND" }
        },
        splits: {
          "1787937600" => { "splitRatio" => "1:10", "date" => 1787937600, "type" => "SPLIT" }
        }
      }
    )
    transport = FakeTransport.new(response: response(result:))
    events = MarketData::YahooFinance::HistoryClient.new(transport:).corporate_action_events(
      identifier:, from: Date.new(2026, 8, 1), to: Date.new(2026, 9, 30)
    )

    assert_equal [ :dividend, :reverse_split ], events.map(&:kind)
    assert_equal BigDecimal("0.25"), events.first.amount
    assert_equal [ 1, 10 ], [ events.last.ratio_numerator, events.last.ratio_denominator ]
    assert_equal "DIVIDEND", events.first.raw_payload.fetch("type")
    query = URI.decode_www_form(transport.uri.query).to_h
    assert_equal "div,splits", query.fetch("events")
  end

  test "treats a response without event data as an empty event set" do
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response))

    assert_empty client.corporate_action_events(
      identifier:, from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31)
    )
  end

  test "rejects malformed corporate-action event containers and payloads" do
    malformed_events = default_result.merge(events: [])
    malformed_client = MarketData::YahooFinance::HistoryClient.new(
      transport: FakeTransport.new(response: response(result: malformed_events))
    )
    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      malformed_client.corporate_action_events(identifier:, from: Date.current - 1.day, to: Date.current)
    end

    malformed_payload = default_result.merge(events: { dividends: { "1" => "bad" } })
    payload_client = MarketData::YahooFinance::HistoryClient.new(
      transport: FakeTransport.new(response: response(result: malformed_payload))
    )
    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      payload_client.corporate_action_events(identifier:, from: Date.current - 1.day, to: Date.current)
    end

    malformed_dividends = default_result.merge(events: { dividends: [] })
    dividends_client = MarketData::YahooFinance::HistoryClient.new(
      transport: FakeTransport.new(response: response(result: malformed_dividends))
    )
    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      dividends_client.corporate_action_events(identifier:, from: Date.current - 1.day, to: Date.current)
    end
  end

  test "skips events outside the requested date range" do
    result = default_result.merge(events: {
      dividends: { "1787851200" => { "amount" => "0.25", "date" => 1787851200 } }
    })
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response(result:)))

    assert_empty client.corporate_action_events(
      identifier:, from: Date.new(2026, 9, 1), to: Date.new(2026, 9, 30)
    )
  end

  test "rejects invalid event dates and amounts" do
    invalid_date = default_result.merge(events: {
      dividends: { "bad" => { "amount" => "0.25", "date" => "bad" } }
    })
    date_client = MarketData::YahooFinance::HistoryClient.new(
      transport: FakeTransport.new(response: response(result: invalid_date))
    )
    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      date_client.corporate_action_events(identifier:, from: Date.current - 1.day, to: Date.current)
    end

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      date_client.send(:normalize_event_amount, 0.25)
    end

    invalid_amount = default_result.merge(events: {
      dividends: { "1787851200" => { "amount" => "not-a-number", "date" => 1787851200 } }
    })
    amount_client = MarketData::YahooFinance::HistoryClient.new(
      transport: FakeTransport.new(response: response(result: invalid_amount))
    )
    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      amount_client.corporate_action_events(identifier:, from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31))
    end
  end

  test "rejects invalid event split ratios" do
    result = default_result.merge(events: {
      splits: { "1787851200" => { "splitRatio" => "0:1", "date" => 1787851200 } }
    })
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response(result:)))

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.corporate_action_events(identifier:, from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31))
    end

    invalid_text = default_result.merge(events: {
      splits: { "1787851200" => { "splitRatio" => "bad", "date" => 1787851200 } }
    })
    text_client = MarketData::YahooFinance::HistoryClient.new(
      transport: FakeTransport.new(response: response(result: invalid_text))
    )
    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      text_client.corporate_action_events(identifier:, from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31))
    end

    increasing = default_result.merge(events: {
      splits: { "1787851200" => { "splitRatio" => "2:1", "date" => 1787851200 } }
    })
    increasing_client = MarketData::YahooFinance::HistoryClient.new(
      transport: FakeTransport.new(response: response(result: increasing))
    )
    assert_equal :split, increasing_client.corporate_action_events(
      identifier:, from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 31)
    ).sole.kind
  end

  test "rejects non-finite event amounts" do
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response))

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.send(:normalize_event_amount, "NaN")
    end
  end

  test "wraps parser argument errors as invalid provider responses" do
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response))
    client.define_singleton_method(:parse_corporate_action_events) { |*| raise ArgumentError, "bad parser input" }

    error = assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.corporate_action_events(identifier:, from: Date.current - 1.day, to: Date.current)
    end
    assert_equal "bad parser input", error.message
  end

  test "URL-encodes a benchmark identifier as a path segment" do
    benchmark_identifier = MarketBenchmark::Providers::YahooFinance::YahooBenchmarkIdentifier.new("^BVSP")
    result = default_result.merge(
      meta: default_result[:meta].merge(symbol: "^BVSP", exchangeName: "SAO", instrumentType: "INDEX")
    )
    transport = FakeTransport.new(response: response(result:))

    MarketData::YahooFinance::HistoryClient.new(transport:).daily_closes(
      identifier: benchmark_identifier, from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26)
    )

    assert_equal "/v8/finance/chart/%5EBVSP", transport.uri.path
  end

  test "rejects malformed quote data" do
    result = default_result.merge(indicators: { quote: [] })
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response(result:)))

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.daily_closes(identifier:, from: Date.current, to: Date.current)
    end
  end

  test "rejects mismatched timestamp and close arrays" do
    result = {
      meta: { symbol: "VOO", exchangeName: "PCX", instrumentType: "ETF", currency: "USD" },
      timestamp: [ 1 ], indicators: { quote: [ { close: [] } ] }
    }
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response(result:)))

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.daily_closes(identifier: MarketData::YahooFinance::Identifier.build(ticker: "VOO", mic: "ARCX"), from: Date.current, to: Date.current)
    end
  end

  test "rejects malformed JSON" do
    client = MarketData::YahooFinance::HistoryClient.new(
      transport: FakeTransport.new(response: MarketData::YahooFinance::Response.new(status: 200, body: "{", headers: {}))
    )

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.daily_closes(identifier: MarketData::YahooFinance::Identifier.build(ticker: "VOO", mic: "ARCX"), from: Date.current, to: Date.current)
    end
  end

  test "rejects an unsuccessful response" do
    client = MarketData::YahooFinance::HistoryClient.new(
      transport: FakeTransport.new(response: MarketData::YahooFinance::Response.new(status: 429, body: "", headers: {}))
    )

    assert_raises(MarketData::YahooFinance::Error) do
      client.daily_closes(identifier:, from: Date.current, to: Date.current)
    end
  end

  test "rejects a chart error" do
    client = MarketData::YahooFinance::HistoryClient.new(
      transport: FakeTransport.new(response: response(result: default_result, error: "Not Found"))
    )

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.daily_closes(identifier:, from: Date.current, to: Date.current)
    end
  end

  test "reports a structured chart error clearly" do
    client = MarketData::YahooFinance::HistoryClient.new(
      transport: FakeTransport.new(response: response(result: default_result, error: { "code" => "Not Found", "description" => "Symbol not found" }))
    )

    error = assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.daily_closes(identifier:, from: Date.current, to: Date.current)
    end

    assert_equal "Symbol not found", error.message
  end

  test "rejects a response without one result" do
    body = { chart: { result: [], error: nil } }.to_json
    client = MarketData::YahooFinance::HistoryClient.new(
      transport: FakeTransport.new(response: MarketData::YahooFinance::Response.new(status: 200, body:, headers: {}))
    )

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.daily_closes(identifier:, from: Date.current, to: Date.current)
    end
  end

  test "rejects a response from another exchange" do
    result = default_result.merge(meta: default_result[:meta].merge(exchangeName: "NMS"))
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response(result:)))

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.daily_closes(identifier: MarketData::YahooFinance::Identifier.build(ticker: "VOO", mic: "ARCX"), from: Date.current, to: Date.current)
    end
  end

  test "rejects a response for another symbol" do
    result = default_result.merge(meta: default_result[:meta].merge(symbol: "VTI"))
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response(result:)))

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.daily_closes(identifier:, from: Date.current, to: Date.current)
    end
  end

  test "rejects a response with an unsupported instrument type" do
    result = default_result.merge(meta: default_result[:meta].merge(instrumentType: "MUTUALFUND"))
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response(result:)))

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.daily_closes(identifier: MarketData::YahooFinance::Identifier.build(ticker: "VOO", mic: "ARCX"), from: Date.current, to: Date.current)
    end
  end

  test "rejects an invalid close price" do
    result = default_result.merge(indicators: { quote: [ { close: [ "not-a-price", nil, BigDecimal("501.25") ] } ] })
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response(result:)))

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.daily_closes(identifier: MarketData::YahooFinance::Identifier.build(ticker: "VOO", mic: "ARCX"), from: Date.current, to: Date.current)
    end
  end

  test "normalizes an invalid timestamp as an invalid response" do
    result = default_result.merge(timestamp: [ "not-a-timestamp", nil, nil ])
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response(result:)))

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.daily_closes(identifier:, from: Date.current, to: Date.current)
    end
  end

  test "rejects a non-positive close price" do
    result = default_result.merge(indicators: { quote: [ { close: [ "0", nil, BigDecimal("501.25") ] } ] })
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response(result:)))

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.daily_closes(identifier:, from: Date.current, to: Date.current)
    end
  end

  test "rejects a float close price before parsing" do
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response))

    assert_raises(MarketData::YahooFinance::InvalidResponse) { client.send(:normalize_price, 1.2) }
  end

  test "rejects an invalid response currency" do
    result = default_result.merge(meta: default_result[:meta].merge(currency: "US"))
    client = MarketData::YahooFinance::HistoryClient.new(transport: FakeTransport.new(response: response(result:)))

    assert_raises(MarketData::YahooFinance::InvalidResponse) do
      client.daily_closes(identifier:, from: Date.current, to: Date.current)
    end
  end

  private

  FakeTransport = Struct.new(:response, :uri) do
    def get(uri)
      self.uri = uri
      response
    end
  end

  def response(result: default_result, error: nil)
    MarketData::YahooFinance::Response.new(status: 200, body: { chart: { result: [ result ], error: } }.to_json, headers: {})
  end

  def identifier
    MarketData::YahooFinance::Identifier.build(ticker: "VOO", mic: "ARCX")
  end

  def default_result
    {
      meta: { symbol: "VOO", exchangeName: "PCX", instrumentType: "ETF", currency: "USD" },
      timestamp: [ Time.utc(2026, 8, 24, 20).to_i, Time.utc(2026, 8, 25, 20).to_i, Time.utc(2026, 8, 26, 20).to_i ],
      indicators: { quote: [ { close: [ BigDecimal("500.12345678"), nil, BigDecimal("501.25") ] } ] }
    }
  end
end
