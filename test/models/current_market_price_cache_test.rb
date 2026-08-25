require "test_helper"

class CurrentMarketPriceCacheTest < ActiveSupport::TestCase
  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @now = Time.utc(2026, 8, 25, 12)
    @instrument = instruments(:voo_arcx)
    @store = CurrentMarketPriceCache.new(cache: @cache, clock: -> { @now })
  end

  test "returns an explicit missing entry" do
    entry = @store.read(instrument: @instrument, provider: "example")

    assert_predicate entry, :missing?
    assert_predicate entry, :refresh_needed?
    assert_nil entry.price
  end

  test "stores a fresh price under a versioned provider and instrument key" do
    price = build_price

    written_entry = @store.write(instrument: @instrument, price:)
    read_entry = @store.read(instrument: @instrument, provider: "example")

    assert_predicate written_entry, :fresh?
    assert_predicate read_entry, :fresh?
    assert_equal price.to_cache_payload, read_entry.price.to_cache_payload
    assert @cache.exist?(cache_key(provider: "example"))
  end

  test "marks an old retained price as stale" do
    @store.write(instrument: @instrument, price: build_price(fetched_at: @now - 30.minutes))

    entry = @store.read(instrument: @instrument, provider: "example")

    assert_predicate entry, :stale?
    assert_predicate entry, :refresh_needed?
  end

  test "retains the last price indefinitely as stale fallback" do
    price = build_price
    @store.write(instrument: @instrument, price:)
    @now += 30.days

    entry = @store.read(instrument: @instrument, provider: "example")

    assert_predicate entry, :stale?
    assert_equal price.to_cache_payload, entry.price.to_cache_payload
  end

  test "replaces the current price without appending history" do
    @store.write(instrument: @instrument, price: build_price(unit_price: "10"))
    @store.write(instrument: @instrument, price: build_price(unit_price: "11"))

    entry = @store.read(instrument: @instrument, provider: "example")

    assert_equal BigDecimal("11"), entry.price.unit_price
    assert @cache.exist?(cache_key(provider: "example"))
  end

  test "keeps providers isolated for the same instrument" do
    @store.write(instrument: @instrument, price: build_price(provider: "one", unit_price: "10"))
    @store.write(instrument: @instrument, price: build_price(provider: "two", unit_price: "20"))

    assert_equal BigDecimal("10"), @store.read(instrument: @instrument, provider: "one").price.unit_price
    assert_equal BigDecimal("20"), @store.read(instrument: @instrument, provider: "two").price.unit_price
  end

  test "treats malformed or mismatched cached values as missing and removes them" do
    key = cache_key(provider: "example")
    @cache.write(key, { "unit_price" => "not-a-price" })

    entry = @store.read(instrument: @instrument, provider: "example")

    assert_predicate entry, :missing?
    assert_not @cache.exist?(key)
  end

  test "raises for an invalid provider identifier supplied by the caller" do
    assert_raises(CurrentMarketPrice::InvalidValue) do
      @store.read(instrument: @instrument, provider: "bad provider")
    end
  end

  test "rejects a quote whose currency does not match its instrument" do
    price = build_price(currency: "BRL")

    assert_raises(CurrentMarketPrice::InvalidValue) do
      @store.write(instrument: @instrument, price:)
    end
  end

  test "cache loss is safe" do
    @store.write(instrument: @instrument, price: build_price)
    @cache.clear

    assert_predicate @store.read(instrument: @instrument, provider: "example"), :missing?
  end

  test "refreshes missing or stale prices and keeps a stale fallback after failure" do
    refreshed_entry = @store.refresh(instrument: @instrument, provider: "example") { build_price(unit_price: "10") }
    assert_equal BigDecimal("10"), refreshed_entry.price.unit_price

    stale_price = build_price(provider: "failing", unit_price: "11", fetched_at: @now - 1.hour)
    @store.write(instrument: @instrument, price: stale_price)

    assert_raises(RuntimeError) do
      @store.refresh(instrument: @instrument, provider: "failing", force: true) { raise "provider unavailable" }
    end

    fallback_entry = @store.read(instrument: @instrument, provider: "failing")
    assert_predicate fallback_entry, :stale?
    assert_equal BigDecimal("11"), fallback_entry.price.unit_price
  end

  test "rejects a refresh result from another provider" do
    assert_raises(CurrentMarketPrice::InvalidValue) do
      @store.refresh(instrument: @instrument, provider: "expected") do
        build_price(provider: "unexpected")
      end
    end

    assert_predicate @store.read(instrument: @instrument, provider: "expected"), :missing?
    assert_predicate @store.read(instrument: @instrument, provider: "unexpected"), :missing?
  end

  test "deduplicates repeated forced refreshes within a short window" do
    refresh_count = 0

    2.times do
      @store.refresh(instrument: @instrument, provider: "example", force: true) do
        refresh_count += 1
        build_price(unit_price: refresh_count.to_s)
      end
    end

    assert_equal 1, refresh_count
    assert_equal BigDecimal("1"), @store.read(instrument: @instrument, provider: "example").price.unit_price
  end

  test "does not refresh an already fresh price unless forced" do
    @store.write(instrument: @instrument, price: build_price(unit_price: "10"))

    entry = @store.refresh(instrument: @instrument, provider: "example") do
      flunk "fresh price should not call the provider"
    end

    assert_predicate entry, :fresh?
    assert_equal BigDecimal("10"), entry.price.unit_price
  end

  test "requires a positive freshness duration" do
    assert_raises(ArgumentError) do
      CurrentMarketPriceCache.new(cache: @cache, fresh_for: 0.seconds)
    end
  end

  private

  def build_price(unit_price: "12.3456", currency: "USD", provider: "example",
    quoted_at: @now - 1.minute, fetched_at: @now - 30.seconds)
    CurrentMarketPrice.new(unit_price:, currency:, provider:, quoted_at:, fetched_at:)
  end

  def cache_key(provider:)
    "localfolio:current_market_price:v1:#{provider}:instrument:#{@instrument.id}"
  end
end
