require "test_helper"

class MarketBenchmark::Providers::BcbTest < ActiveSupport::TestCase
  test "uses the Brazilian banking calendar for expected CDI dates" do
    provider = MarketBenchmark::Providers::Bcb.new(client: Object.new)

    assert_equal [ Date.new(2026, 9, 8) ], provider.expected_dates(
      from: Date.new(2026, 9, 7), to: Date.new(2026, 9, 8)
    )
  end

  test "allows one Brazilian banking day for CDI publication" do
    provider = MarketBenchmark::Providers::Bcb.new(client: Object.new)

    assert_equal Date.new(2026, 9, 10), provider.available_through(on: Date.new(2026, 9, 12))
    assert_equal Date.new(2026, 9, 11), provider.available_through(on: Date.new(2026, 9, 14))
  end

  test "supports CDI rate benchmarks and maps client observations" do
    benchmark = MarketBenchmark.new(identifier: "CDI", name: "CDI", kind: :rate, currency: "BRL",
      provider: "bcb", provider_identifier: "CDI")
    observation = MarketData::Bcb::Client::Observation.new(observed_on: Date.new(2026, 9, 8),
      value: BigDecimal("0.0005"), observed_at: Time.utc(2026, 9, 8))
    client = Object.new
    client.define_singleton_method(:daily_rates) { |**| [ observation ] }
    provider = MarketBenchmark::Providers::Bcb.new(client:)

    assert provider.supports?(benchmark:)
    result = provider.fetch(benchmark:, from: observation.observed_on, to: observation.observed_on)

    assert_equal observation.value, result.sole.value
    assert_equal "BRL", result.sole.currency
    assert_equal "bcb", result.sole.provider
  end

  test "rejects non-CDI or non-rate benchmarks" do
    provider = MarketBenchmark::Providers::Bcb.new(client: Object.new)
    price = MarketBenchmark.new(provider: "bcb", kind: :price, provider_identifier: "CDI")
    other = MarketBenchmark.new(provider: "bcb", kind: :rate, provider_identifier: "SELIC")

    assert_not provider.supports?(benchmark: price)
    assert_not provider.supports?(benchmark: other)
    assert_empty provider.fetch(benchmark: price, from: Date.current, to: Date.current)
  end
end
