require "test_helper"

class ExchangeRateCacheTest < ActiveSupport::TestCase
  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @store = ExchangeRateCache.new(cache: @cache, fresh_for: 30.minutes)
  end

  test "returns a missing lookup when no rate is cached" do
    assert_predicate @store.read(base_currency: "USD", quote_currency: "BRL", provider: "yahoo_finance_fx"), :missing?
  end

  test "round trips a precise rate and reports it as fresh" do
    rate = build_rate(rate: "5.123456789")

    @store.write(exchange_rate: rate)
    lookup = @store.read(base_currency: "USD", quote_currency: "BRL", provider: "yahoo_finance_fx")

    assert_predicate lookup, :fresh?
    assert_equal BigDecimal("5.123456789"), lookup.exchange_rate.rate
  end

  test "retains a stale rate as a fallback" do
    rate = build_rate(fetched_at: 31.minutes.ago)

    @store.write(exchange_rate: rate)

    assert_predicate @store.read(base_currency: "USD", quote_currency: "BRL", provider: "yahoo_finance_fx"), :stale?
  end

  test "rejects values that are not exchange rates" do
    assert_raises(ArgumentError) { @store.write(exchange_rate: Object.new) }
  end

  test "discards a malformed cached payload" do
    @cache.write("localfolio:exchange_rate:v1:yahoo_finance_fx:USD:BRL", "invalid")

    assert_predicate @store.read(base_currency: "USD", quote_currency: "BRL", provider: "yahoo_finance_fx"), :missing?
  end

  test "discards a cached rate whose values do not match the requested pair" do
    @cache.write(
      "localfolio:exchange_rate:v1:yahoo_finance_fx:USD:BRL",
      build_rate(rate: "5").to_cache_payload.merge("quote_currency" => "EUR")
    )

    assert_predicate @store.read(base_currency: "USD", quote_currency: "BRL", provider: "yahoo_finance_fx"), :missing?
  end

  test "discards a cached rate that is not positive and finite" do
    [ "0", "-1", "NaN", "Infinity" ].each do |rate|
      @cache.write(
        "localfolio:exchange_rate:v1:yahoo_finance_fx:USD:BRL",
        build_rate(rate:).to_cache_payload
      )

      assert_predicate @store.read(base_currency: "USD", quote_currency: "BRL", provider: "yahoo_finance_fx"), :missing?, rate
    end
  end

  test "reuses a fresh rate without calling the refresh block" do
    rate = build_rate(rate: "5")
    @store.write(exchange_rate: rate)

    lookup = @store.refresh(base_currency: "USD", quote_currency: "BRL", provider: "yahoo_finance_fx") do
      raise "fresh cache should skip provider"
    end

    assert_predicate lookup, :fresh?
  end

  test "does not publish a rate when its generation is superseded" do
    fence = Object.new
    fence.define_singleton_method(:capture) { "generation-1" }
    fence.define_singleton_method(:publish) { |generation| :superseded }

    lookup = @store.refresh(base_currency: "USD", quote_currency: "BRL", provider: "yahoo_finance_fx", fence:) do
      build_rate(rate: "9")
    end

    assert_predicate lookup, :missing?
  end

  test "refreshes a stale rate without a publication fence" do
    @store.write(exchange_rate: build_rate(rate: "5", fetched_at: 31.minutes.ago))

    lookup = @store.refresh(base_currency: "USD", quote_currency: "BRL", provider: "yahoo_finance_fx") do
      build_rate(rate: "6")
    end

    assert_equal BigDecimal("6"), lookup.exchange_rate.rate
  end

  test "requires positive freshness" do
    assert_raises(ArgumentError) { ExchangeRateCache.new(cache: @cache, fresh_for: 0.seconds) }
  end

  private

  def build_rate(rate: "5.1", fetched_at: Time.current)
    ExchangeRate::Rate.new(
      base_currency: "USD", quote_currency: "BRL", rate: BigDecimal(rate),
      observed_at: Time.current, fetched_at:, provider: "yahoo_finance_fx"
    )
  end
end
