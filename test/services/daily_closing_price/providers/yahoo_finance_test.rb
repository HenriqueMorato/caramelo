require "test_helper"

class DailyClosingPrice::Providers::YahooFinanceTest < ActiveSupport::TestCase
  test "builds a default history client" do
    provider = DailyClosingPrice::Providers::YahooFinance.new

    assert_instance_of MarketData::YahooFinance::HistoryClient, provider.send(:client)
  end

  test "returns supported observations with the provider identity" do
    instrument = instruments(:voo_arcx)
    provider = DailyClosingPrice::Providers::YahooFinance.new(client: FakeClient.new)

    observations = provider.fetch(instrument:, from: Date.new(2026, 8, 24), to: Date.new(2026, 8, 26))

    assert_equal 1, observations.size
    assert_equal instrument, observations.first.instrument
    assert_equal "USD", observations.first.currency
    assert_equal "yahoo_finance", observations.first.provider
  end

  test "does not request unsupported markets" do
    instrument = Instrument.new(ticker: "UNKNOWN", exchange: "XXXX", name: "Unknown", currency: "USD")
    client = FakeClient.new

    observations = DailyClosingPrice::Providers::YahooFinance.new(client:).fetch(
      instrument:, from: Date.current, to: Date.current
    )

    assert_empty observations
    assert_empty client.requests
  end

  FakeClient = Struct.new(:requests) do
    def initialize
      super([])
    end

    def daily_closes(identifier:, from:, to:)
      requests << [ identifier.value, from, to ]
      [ MarketData::YahooFinance::HistoryClient::DailyClose.new(
        close_price: BigDecimal("500.12345678"), currency: "USD",
        trading_date: Date.new(2026, 8, 24), observed_at: Time.utc(2026, 8, 24, 20)
      ) ]
    end
  end
end
