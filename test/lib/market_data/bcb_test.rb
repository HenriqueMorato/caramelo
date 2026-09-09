require "test_helper"

class MarketData::Bcb::ClientTest < ActiveSupport::TestCase
  Response = Data.define(:code, :body)

  test "parses CDI percentages into decimal daily rates" do
    client = build_client('[{"data":"02/01/2026","valor":"0,055131"},{"data":"05/01/2026","valor":"0,051660"}]')

    observations = client.daily_rates(identifier: "CDI", from: Date.new(2026, 1, 2), to: Date.new(2026, 1, 5))

    assert_equal [ Date.new(2026, 1, 2), Date.new(2026, 1, 5) ], observations.map(&:observed_on)
    assert_equal BigDecimal("0.00055131"), observations.first.value
  end

  test "sorts and filters rows to the requested interval" do
    client = build_client('[{"data":"07/01/2026","valor":"0,05"},{"data":"01/01/2026","valor":"0,04"},{"data":"03/01/2026","valor":"0,06"}]')

    observations = client.daily_rates(identifier: "CDI", from: Date.new(2026, 1, 2), to: Date.new(2026, 1, 7))

    assert_equal [ Date.new(2026, 1, 3), Date.new(2026, 1, 7) ], observations.map(&:observed_on)
  end

  test "rejects unsupported series and ranges beyond ten years" do
    client = build_client("[]")

    assert_raises(MarketData::Bcb::InvalidResponse) do
      client.daily_rates(identifier: "SELIC", from: Date.new(2026, 1, 1), to: Date.new(2026, 1, 2))
    end
    assert_raises(MarketData::Bcb::InvalidResponse) do
      client.daily_rates(identifier: "CDI", from: Date.new(2010, 1, 1), to: Date.new(2026, 1, 1))
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

  private

  def build_client(body, code: "200")
    connection = Object.new
    connection.define_singleton_method(:get) { |_path| Response.new(code:, body:) }
    http = Object.new
    http.define_singleton_method(:start) { |_host, _port, **_options, &block| block.call(connection) }
    MarketData::Bcb::Client.new(http:)
  end
end
