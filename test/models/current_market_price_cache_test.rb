require "test_helper"

class CurrentMarketPriceCacheTest < ActiveSupport::TestCase
  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @now = Time.utc(2026, 8, 25, 12)
    travel_to @now
    @instrument = instruments(:voo_arcx)
    @store = CurrentMarketPriceCache.new(cache: @cache)
  end

  test "returns an explicit missing lookup" do
    lookup = @store.read(instrument: @instrument, provider: "example")

    assert_predicate lookup, :missing?
    assert_predicate lookup, :refresh_needed?
    assert_nil lookup.current_market_price
  end

  test "stores a fresh price under a versioned provider and instrument key" do
    current_market_price = build_current_market_price

    written_lookup = @store.write(instrument: @instrument, current_market_price:)
    read_lookup = @store.read(instrument: @instrument, provider: "example")

    assert_predicate written_lookup, :fresh?
    assert_predicate read_lookup, :fresh?
    assert_equal current_market_price.to_cache_payload, read_lookup.current_market_price.to_cache_payload
    assert @cache.exist?(cache_key(provider: "example"))
  end

  test "marks an old retained price as stale" do
    @store.write(
      instrument: @instrument,
      current_market_price: build_current_market_price(fetched_at: @now - 30.minutes)
    )

    lookup = @store.read(instrument: @instrument, provider: "example")

    assert_predicate lookup, :stale?
    assert_predicate lookup, :refresh_needed?
  end

  test "retains the last price indefinitely as stale fallback" do
    current_market_price = build_current_market_price
    @store.write(instrument: @instrument, current_market_price:)
    travel 30.days

    lookup = @store.read(instrument: @instrument, provider: "example")

    assert_predicate lookup, :stale?
    assert_equal current_market_price.to_cache_payload, lookup.current_market_price.to_cache_payload
  end

  test "replaces the current price without appending history" do
    @store.write(instrument: @instrument, current_market_price: build_current_market_price(unit_price: "10"))
    @store.write(instrument: @instrument, current_market_price: build_current_market_price(unit_price: "11"))

    lookup = @store.read(instrument: @instrument, provider: "example")

    assert_equal BigDecimal("11"), lookup.current_market_price.unit_price
    assert @cache.exist?(cache_key(provider: "example"))
  end

  test "keeps providers isolated for the same instrument" do
    @store.write(
      instrument: @instrument,
      current_market_price: build_current_market_price(provider: "one", unit_price: "10")
    )
    @store.write(
      instrument: @instrument,
      current_market_price: build_current_market_price(provider: "two", unit_price: "20")
    )

    first_provider_lookup = @store.read(instrument: @instrument, provider: "one")
    second_provider_lookup = @store.read(instrument: @instrument, provider: "two")

    assert_equal BigDecimal("10"), first_provider_lookup.current_market_price.unit_price
    assert_equal BigDecimal("20"), second_provider_lookup.current_market_price.unit_price
  end

  test "treats malformed or mismatched cached values as missing and removes them" do
    key = cache_key(provider: "example")
    @cache.write(key, { "unit_price" => "not-a-price" })

    lookup = @store.read(instrument: @instrument, provider: "example")

    assert_predicate lookup, :missing?
    assert_not @cache.exist?(key)
  end

  test "discards cached values whose provider or currency does not match the key" do
    mismatched_values = [
      build_current_market_price(provider: "other").to_cache_payload,
      build_current_market_price(currency: "BRL").to_cache_payload
    ]

    mismatched_values.each do |payload|
      key = cache_key(provider: "example")
      @cache.write(key, payload)

      assert_predicate @store.read(instrument: @instrument, provider: "example"), :missing?
      assert_not @cache.exist?(key)
    end
  end

  test "raises for an invalid provider identifier supplied by the caller" do
    assert_raises(CurrentMarketPrice::InvalidValue) do
      @store.read(instrument: @instrument, provider: "bad provider")
    end
  end

  test "rejects a quote whose currency does not match its instrument" do
    current_market_price = build_current_market_price(currency: "BRL")

    assert_raises(CurrentMarketPrice::InvalidValue) do
      @store.write(instrument: @instrument, current_market_price:)
    end
  end

  test "rejects values that are not current market prices" do
    assert_raises(ArgumentError) do
      @store.write(instrument: @instrument, current_market_price: "12.34")
    end
  end

  test "requires a persisted instrument" do
    instrument = Instrument.new(currency: "USD")

    assert_raises(ArgumentError) do
      @store.read(instrument:, provider: "example")
    end
  end

  test "cache loss is safe" do
    @store.write(instrument: @instrument, current_market_price: build_current_market_price)
    @cache.clear

    assert_predicate @store.read(instrument: @instrument, provider: "example"), :missing?
  end

  test "refreshes missing or stale prices and keeps a stale fallback after failure" do
    refreshed_lookup = @store.refresh(instrument: @instrument, provider: "example") do
      build_current_market_price(unit_price: "10")
    end
    assert_equal BigDecimal("10"), refreshed_lookup.current_market_price.unit_price

    stale_current_market_price = build_current_market_price(
      provider: "failing",
      unit_price: "11",
      fetched_at: @now - 1.hour
    )
    @store.write(instrument: @instrument, current_market_price: stale_current_market_price)

    assert_raises(RuntimeError) do
      @store.refresh(instrument: @instrument, provider: "failing", force: true) { raise "provider unavailable" }
    end

    fallback_lookup = @store.read(instrument: @instrument, provider: "failing")
    assert_predicate fallback_lookup, :stale?
    assert_equal BigDecimal("11"), fallback_lookup.current_market_price.unit_price
  end

  test "rejects a refresh result from another provider" do
    assert_raises(CurrentMarketPrice::InvalidValue) do
      @store.refresh(instrument: @instrument, provider: "expected") do
        build_current_market_price(provider: "unexpected")
      end
    end

    assert_predicate @store.read(instrument: @instrument, provider: "expected"), :missing?
    assert_predicate @store.read(instrument: @instrument, provider: "unexpected"), :missing?
  end

  test "force refreshes even when the current price is fresh" do
    refresh_count = 0

    2.times do
      @store.refresh(instrument: @instrument, provider: "example", force: true) do
        refresh_count += 1
        build_current_market_price(unit_price: refresh_count.to_s)
      end
    end

    lookup = @store.read(instrument: @instrument, provider: "example")

    assert_equal 2, refresh_count
    assert_equal BigDecimal("2"), lookup.current_market_price.unit_price
  end

  test "does not refresh an already fresh price unless forced" do
    @store.write(instrument: @instrument, current_market_price: build_current_market_price(unit_price: "10"))

    lookup = @store.refresh(instrument: @instrument, provider: "example") do
      flunk "fresh price should not call the provider"
    end

    assert_predicate lookup, :fresh?
    assert_equal BigDecimal("10"), lookup.current_market_price.unit_price
  end

  test "requires a positive freshness duration" do
    assert_raises(ArgumentError) do
      CurrentMarketPriceCache.new(cache: @cache, fresh_for: 0.seconds)
    end
  end

  private

  def build_current_market_price(unit_price: "12.3456", currency: "USD", provider: "example",
    quoted_at: @now - 1.minute, fetched_at: @now - 30.seconds)
    CurrentMarketPrice.new(unit_price:, currency:, provider:, quoted_at:, fetched_at:)
  end

  def cache_key(provider:)
    "localfolio:current_market_price:v1:#{provider}:instrument:#{@instrument.id}"
  end
end
