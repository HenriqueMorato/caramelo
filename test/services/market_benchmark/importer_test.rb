require "test_helper"

class MarketBenchmark::ImporterTest < ActiveSupport::TestCase
  setup do
    MarketBenchmarkObservation.delete_all
    MarketBenchmark.delete_all
  end

  test "builds the default provider and delegates support and identifier" do
    importer = MarketBenchmark::Importer.default
    benchmark = MarketBenchmark.new(provider: "yahoo_finance", kind: "price")

    assert_instance_of MarketBenchmark::Providers::YahooFinance, importer.instance_variable_get(:@provider)
    assert importer.supports?(benchmark:)
    assert_equal "yahoo_finance", importer.identifier
  end

  test "persists inside a current publication fence" do
    benchmark = MarketBenchmark.create!(identifier: "FENCE", name: "Fenced benchmark", kind: :price,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "^FENCE")
    observation = MarketBenchmarkObservation::Observation.new(market_benchmark: benchmark,
      observed_on: Date.new(2026, 8, 28), value: BigDecimal("5000"), currency: "USD",
      provider: "yahoo_finance", observed_at: Time.current)
    provider = Object.new
    provider.define_singleton_method(:identifier) { "yahoo_finance" }
    provider.define_singleton_method(:fetch) { |**| [ observation ] }
    fence = Object.new
    fence.define_singleton_method(:capture) { "generation-1" }
    fence.define_singleton_method(:publish) { |generation, &block| block.call; :published }

    result = MarketBenchmark::Importer.new(provider:).call(benchmark:, from: observation.observed_on,
      to: observation.observed_on, fence:)

    assert_equal 1, result.created_count
  end

  test "skips persistence when a newer publication generation wins" do
    benchmark = MarketBenchmark.create!(identifier: "SUPERSEDED", name: "Superseded benchmark", kind: :price,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "^SUPERSEDED")
    provider = Object.new
    provider.define_singleton_method(:identifier) { "yahoo_finance" }
    provider.define_singleton_method(:fetch) { |**| [] }
    fence = Object.new
    fence.define_singleton_method(:capture) { "generation-1" }
    fence.define_singleton_method(:publish) { |generation| :superseded }

    result = MarketBenchmark::Importer.new(provider:).call(benchmark:, from: Date.new(2026, 8, 28),
      to: Date.new(2026, 8, 28), fence:)

    assert_equal 0, result.created_count
  end

  test "rejects a reversed date range" do
    provider = Object.new
    provider.define_singleton_method(:identifier) { "yahoo_finance" }
    provider.define_singleton_method(:fetch) { |**| [] }

    assert_raises(ArgumentError) do
      MarketBenchmark::Importer.new(provider:).call(
        benchmark: MarketBenchmark.new, from: Date.current, to: Date.current - 1
      )
    end
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

    updated = observation.with(value: BigDecimal("5001"))
    provider.define_singleton_method(:fetch) { |**| [ updated ] }
    result = MarketBenchmark::Importer.new(provider:).call(
      benchmark:, from: observation.observed_on, to: observation.observed_on
    )
    assert_equal 0, result.created_count
    assert_equal 1, result.updated_count
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
