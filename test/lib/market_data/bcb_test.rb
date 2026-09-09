require "test_helper"

class MarketData::Bcb::ClientTest < ActiveSupport::TestCase
  Response = Data.define(:code, :body)

  test "parses CDI percentages into decimal daily rates" do
    client = build_client('[{"data":"02/01/2026","valor":"0,055131"},{"data":"05/01/2026","valor":"0,051660"}]')

    observations = client.daily_rates(identifier: "CDI", from: Date.new(2026, 1, 2), to: Date.new(2026, 1, 5))

    assert_equal [ Date.new(2026, 1, 2), Date.new(2026, 1, 5) ], observations.map(&:observed_on)
    assert_equal BigDecimal("0.00055131"), observations.first.value
  end

  test "requests the SGS series 12 endpoint" do
    paths = []
    client = build_client("[]", paths:)

    client.daily_rates(identifier: "CDI", from: Date.new(2026, 1, 2), to: Date.new(2026, 1, 2))

    assert_equal "/dados/serie/bcdata.sgs.12/dados", URI(paths.sole).path
  end

  test "sorts and filters rows to the requested interval" do
    client = build_client('[{"data":"07/01/2026","valor":"0,05"},{"data":"01/01/2026","valor":"0,04"},{"data":"03/01/2026","valor":"0,06"}]')

    observations = client.daily_rates(identifier: "CDI", from: Date.new(2026, 1, 2), to: Date.new(2026, 1, 7))

    assert_equal [ Date.new(2026, 1, 3), Date.new(2026, 1, 7) ], observations.map(&:observed_on)
  end

  test "ignores negative and non-finite rates" do
    body = '[{"data":"03/01/2026","valor":"-0,01"},{"data":"04/01/2026","valor":"NaN"}]'

    assert_empty build_client(body).daily_rates(
      identifier: "CDI", from: Date.new(2026, 1, 3), to: Date.new(2026, 1, 4)
    )
  end

  test "rejects unsupported series and splits ranges beyond ten years" do
    client = build_client("[]")

    assert_raises(MarketData::Bcb::InvalidResponse) do
      client.daily_rates(identifier: "SELIC", from: Date.new(2026, 1, 1), to: Date.new(2026, 1, 2))
    end
    observations = client.daily_rates(identifier: "CDI", from: Date.new(2010, 1, 1), to: Date.new(2026, 1, 1))

    assert_empty observations
  end

  test "rejects ranges that are not chronological dates" do
    assert_raises(MarketData::Bcb::InvalidResponse) do
      build_client("[]").daily_rates(
        identifier: "CDI", from: Date.new(2026, 1, 2), to: Date.new(2026, 1, 1)
      )
    end

    assert_raises(MarketData::Bcb::InvalidResponse) do
      build_client("[]").daily_rates(identifier: "CDI", from: "2026-01-01", to: Date.new(2026, 1, 2))
    end
  end

  test "rejects malformed responses and non-success statuses" do
    assert_raises(MarketData::Bcb::InvalidResponse) do
      build_client("{}", code: "200").daily_rates(identifier: "CDI", from: Date.new(2026, 1, 1), to: Date.new(2026, 1, 2))
    end
    assert_raises(MarketData::Bcb::InvalidResponse) do
      build_client("[]", code: "500").daily_rates(identifier: "CDI", from: Date.new(2026, 1, 1), to: Date.new(2026, 1, 2))
    end
  end

  test "treats the documented no-values response as an empty range" do
    body = '{"erro":{"statusCode":404,"detail":"Value(s) not found"}}'

    assert_empty build_client(body, code: "404").daily_rates(
      identifier: "CDI", from: Date.new(2026, 1, 3), to: Date.new(2026, 1, 4)
    )
  end

  test "does not treat an undecodable not-found response as an empty range" do
    assert_raises(MarketData::Bcb::InvalidResponse) do
      build_client("not-json", code: "404").daily_rates(
        identifier: "CDI", from: Date.new(2026, 1, 3), to: Date.new(2026, 1, 4)
      )
    end
  end

  test "wraps network failures in the provider error" do
    http = Object.new
    http.define_singleton_method(:start) { |*| raise SocketError, "connection failed" }

    assert_raises(MarketData::Bcb::Error) do
      MarketData::Bcb::Client.new(http:).daily_rates(
        identifier: "CDI", from: Date.new(2026, 1, 3), to: Date.new(2026, 1, 4)
      )
    end
  end

  private

  def build_client(body, code: "200", paths: [])
    connection = Object.new
    connection.define_singleton_method(:get) do |path|
      paths << "https://api.bcb.gov.br#{path}"
      Response.new(code:, body:)
    end
    http = Object.new
    http.define_singleton_method(:start) { |_host, _port, **_options, &block| block.call(connection) }
    MarketData::Bcb::Client.new(http:)
  end
end
