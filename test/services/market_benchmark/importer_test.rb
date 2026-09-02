require "test_helper"

class MarketBenchmark::ImporterTest < ActiveSupport::TestCase
  setup do
    MarketBenchmarkObservation.delete_all
    MarketBenchmark.delete_all
  end

  test "persists provider observations and reports counts" do
    benchmark = MarketBenchmark.create!(
      identifier: "SP500", name: "S&P 500", kind: "price", currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^GSPC"
    )
    observation = MarketBenchmarkObservation::Observation.new(
      market_benchmark: benchmark, observed_on: Date.new(2026, 8, 28), value: BigDecimal("5000"),
      currency: "USD", provider: "yahoo_finance", observed_at: Time.utc(2026, 8, 28, 20)
    )
    provider = Object.new
    provider.define_singleton_method(:identifier) { "yahoo_finance" }
    provider.define_singleton_method(:supports?) { |benchmark:| benchmark.provider == "yahoo_finance" }
    provider.define_singleton_method(:fetch) { |**| [ observation ] }

    result = MarketBenchmark::Importer.new(provider:).call(
      benchmark:, from: observation.observed_on, to: observation.observed_on
    )

    assert_equal 1, result.created_count
    assert_equal 0, result.updated_count
    assert_equal observation.value, benchmark.observations.sole.value
  end

  test "rejects observations from another benchmark" do
    benchmark = MarketBenchmark.create!(
      identifier: "SP500", name: "S&P 500", kind: "price", currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^GSPC"
    )
    other = MarketBenchmark.create!(
      identifier: "IBOV", name: "Ibovespa", kind: "price", currency: "BRL",
      provider: "yahoo_finance", provider_identifier: "^BVSP"
    )
    provider = Object.new
    provider.define_singleton_method(:identifier) { "yahoo_finance" }
    provider.define_singleton_method(:fetch) { |**| [ MarketBenchmarkObservation::Observation.new(
      market_benchmark: other, observed_on: Date.current, value: BigDecimal("1"),
      currency: "BRL", provider: "yahoo_finance", observed_at: Time.current
    ) ] }

    assert_raises(ArgumentError) do
      MarketBenchmark::Importer.new(provider:).call(benchmark:, from: Date.current, to: Date.current)
    end
  end
end
