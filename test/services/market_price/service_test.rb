require "test_helper"

class MarketPrice::ServiceTest < ActiveSupport::TestCase
  setup do
    @instrument = instruments(:petr4_bvmf)
    @cache = ActiveSupport::Cache::MemoryStore.new
    @provider = FakeProvider.new
    @service = MarketPrice::Service.new(
      provider: @provider,
      cache: CurrentMarketPriceCache.new(cache: @cache)
    )
  end

  test "uses the injected strategy without requiring a provider from callers" do
    lookup = @service.refresh(instrument: @instrument)

    assert_predicate lookup, :fresh?
    assert_equal 1, @provider.fetch_count
    assert_equal BigDecimal("32.45"), @service.read(instrument: @instrument).current_market_price.unit_price
  end

  test "skips fresh prices unless the refresh is forced" do
    @service.refresh(instrument: @instrument)
    @service.refresh(instrument: @instrument)
    @service.refresh(instrument: @instrument, force: true)

    assert_equal 2, @provider.fetch_count
  end

  test "keeps the provider identifier inside the service and cache" do
    @service.refresh(instrument: @instrument)

    payload = @cache.read("localfolio:current_market_price:v1:fake:instrument:#{@instrument.id}")

    assert_equal "fake", payload.fetch("provider")
  end

  test "default service supports B3 and initial US provider instruments" do
    service = MarketPrice::Service.default

    assert service.supports?(instrument: @instrument)
    assert service.supports?(instrument: instruments(:voo_arcx))
    assert service.supports?(
      instrument: Instrument.new(ticker: "VWRA", exchange: "XLON", name: "Vanguard FTSE All-World", currency: "USD")
    )
    assert_not service.supports?(
      instrument: Instrument.new(ticker: "VWRA", exchange: "XSWX", name: "Vanguard FTSE All-World", currency: "CHF")
    )
  end

  test "returns nil when reading an unsupported instrument" do
    @provider.supported = false

    assert_nil @service.read(instrument: @instrument)
  end

  test "raises explicitly when refreshing an unsupported instrument" do
    @provider.supported = false

    assert_raises(MarketPrice::UnsupportedInstrument) do
      @service.refresh(instrument: @instrument)
    end
  end

  private

  class FakeProvider
    attr_accessor :supported
    attr_reader :fetch_count

    def initialize
      @supported = true
      @fetch_count = 0
    end

    def identifier
      "fake"
    end

    def supports?(instrument:)
      supported
    end

    def fetch(instrument:)
      @fetch_count += 1
      CurrentMarketPrice.new(
        unit_price: "32.45",
        currency: instrument.currency,
        provider: identifier,
        quoted_at: Time.current,
        fetched_at: Time.current
      )
    end
  end
end
