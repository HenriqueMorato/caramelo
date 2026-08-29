require "test_helper"

class ExchangeRate::ServiceTest < ActiveSupport::TestCase
  test "does not request a provider rate for the reporting currency" do
    provider = FakeProvider.new
    service = ExchangeRate::Service.new(provider:, cache: ExchangeRateCache.new(cache: ActiveSupport::Cache::MemoryStore.new))

    lookup = service.read(base_currency: "BRL", quote_currency: "BRL")

    assert_predicate lookup, :same_currency?
    assert_empty provider.requests
  end

  test "does not refresh FX for the reporting currency" do
    provider = FakeProvider.new
    service = ExchangeRate::Service.new(provider:, cache: ExchangeRateCache.new(cache: ActiveSupport::Cache::MemoryStore.new))

    lookup = service.refresh(base_currency: "BRL", quote_currency: "BRL") { raise "provider should not run" }

    assert_predicate lookup, :same_currency?
    assert_empty provider.requests
  end

  test "refreshes a foreign currency pair through the provider" do
    provider = FakeProvider.new
    service = ExchangeRate::Service.new(provider:, cache: ExchangeRateCache.new(cache: ActiveSupport::Cache::MemoryStore.new))

    lookup = service.refresh(base_currency: "USD", quote_currency: "BRL")

    assert_predicate lookup, :fresh?
    assert_equal [ [ "USD", "BRL" ] ], provider.requests
    assert_equal BigDecimal("5.12"), lookup.exchange_rate.rate
  end

  FakeProvider = Struct.new(:requests) do
    def initialize
      super([])
    end

    def identifier = "fake"

    def fetch(base_currency:, quote_currency:)
      requests << [ base_currency, quote_currency ]
      ExchangeRate::Rate.new(
        base_currency:, quote_currency:, rate: BigDecimal("5.12"),
        observed_on: Date.current, fetched_at: Time.current, provider: identifier
      )
    end
  end
end
