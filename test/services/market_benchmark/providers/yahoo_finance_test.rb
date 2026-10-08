require "test_helper"

class MarketBenchmark::Providers::YahooFinanceTest < ActiveSupport::TestCase
  test "builds a default history client" do
    assert_instance_of MarketData::YahooFinance::HistoryClient, described_class.new.send(:client)
  end

  test "returns observations for supported yahoo price benchmarks" do
    benchmark = MarketBenchmark.new(
      identifier: "SP500", name: "S&P 500", kind: "price", currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^GSPC"
    )
    provider = described_class.new(client: FakeClient.new)

    observation = provider.fetch(benchmark:, from: Date.current - 1, to: Date.current).sole

    assert_equal benchmark, observation.market_benchmark
    assert_equal "USD", observation.currency
    assert_equal "yahoo_finance", observation.provider
  end

  test "supports total-return index benchmarks" do
    benchmark = MarketBenchmark.new(
      identifier: "ACWI_IMI_NET", name: "MSCI ACWI IMI", kind: "total_return", currency: "USD",
      provider: "yahoo_finance", provider_identifier: "IMID.L", return_convention: "net"
    )
    provider = described_class.new(client: FakeClient.new)

    assert provider.supports?(benchmark:)
    assert_equal "USD", provider.fetch(benchmark:, from: Date.current - 1, to: Date.current).sole.currency
  end

  test "exposes the listed start of the seeded global proxy" do
    benchmark = MarketBenchmark.new(provider: "yahoo_finance", provider_identifier: "IMID.L")

    assert_equal Date.new(2011, 7, 26), described_class.new(client: FakeClient.new).available_from(benchmark:)
  end

  test "does not request unsupported benchmark providers or rate benchmarks" do
    client = FakeClient.new
    provider = described_class.new(client:)
    bcb = MarketBenchmark.new(
      identifier: "CDI", name: "CDI", kind: "rate", currency: "BRL", provider: "bcb", provider_identifier: "CDI"
    )

    assert_empty provider.fetch(benchmark: bcb, from: Date.current - 1, to: Date.current)
    assert_not provider.supports?(benchmark: bcb)
    assert_empty client.requests
  end

  test "rejects a benchmark without a provider identifier" do
    benchmark = MarketBenchmark.new(provider: "yahoo_finance", kind: "price", provider_identifier: " ")

    assert_raises(MarketData::YahooFinance::InvalidIdentifier) do
      described_class.new(client: FakeClient.new).fetch(benchmark:, from: Date.current - 1, to: Date.current)
    end
  end

  FakeClient = Struct.new(:requests) do
    def initialize
      super([])
    end

    def daily_closes(identifier:, from:, to:)
      requests << [ identifier.value, from, to ]
      [ MarketData::YahooFinance::HistoryClient::DailyClose.new(
        close_price: BigDecimal("5000.12"), currency: "USD", trading_date: Date.current - 1,
        observed_at: Time.utc(2026, 8, 28, 20)
      ) ]
    end
  end

  def described_class
    MarketBenchmark::Providers::YahooFinance
  end
end
