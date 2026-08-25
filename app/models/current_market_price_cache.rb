class CurrentMarketPriceCache
  CACHE_VERSION = 1
  DEFAULT_FRESH_FOR = 30.minutes
  DEFAULT_REFRESH_DEDUPLICATION_WINDOW = 15.seconds

  Entry = Data.define(:price, :status) do
    def fresh?
      status == :fresh
    end

    def stale?
      status == :stale
    end

    def missing?
      status == :missing
    end

    def refresh_needed?
      !fresh?
    end
  end

  def initialize(cache: Rails.cache, fresh_for: DEFAULT_FRESH_FOR,
    refresh_deduplication_window: DEFAULT_REFRESH_DEDUPLICATION_WINDOW, clock: -> { Time.current })
    raise ArgumentError, "freshness must be positive" unless fresh_for.positive?
    raise ArgumentError, "refresh deduplication window must be positive" unless refresh_deduplication_window.positive?

    @cache = cache
    @fresh_for = fresh_for
    @refresh_deduplication_window = refresh_deduplication_window
    @clock = clock
  end

  def read(instrument:, provider:)
    normalized_provider = CurrentMarketPrice.normalize_provider(provider)
    key = cache_key(instrument:, provider: normalized_provider)
    payload = cache.read(key)
    return missing_entry unless payload

    price = CurrentMarketPrice.from_cache_payload(payload)
    raise CurrentMarketPrice::InvalidPayload, "provider does not match cache key" unless price.provider == normalized_provider
    raise CurrentMarketPrice::InvalidPayload, "currency does not match instrument" unless price.currency == instrument.currency

    entry_for(price)
  rescue CurrentMarketPrice::InvalidPayload
    # Cached quotes are replaceable, so corrupt data is safer to discard.
    cache.delete(key) if key
    missing_entry
  end

  def write(instrument:, price:)
    raise ArgumentError, "price must be a CurrentMarketPrice" unless price.is_a?(CurrentMarketPrice)
    raise CurrentMarketPrice::InvalidValue, "currency does not match instrument" unless price.currency == instrument.currency

    # No expiry: the last known quote remains available as stale fallback.
    cache.write(cache_key(instrument:, provider: price.provider), price.to_cache_payload)
    entry_for(price)
  end

  def refresh(instrument:, provider:, force: false)
    current_entry = read(instrument:, provider:)
    return current_entry if current_entry.fresh? && !force

    normalized_provider = CurrentMarketPrice.normalize_provider(provider)
    # Share rapid repeat refreshes; provider jobs add strict concurrency control.
    cache.fetch(refresh_key(instrument:, provider: normalized_provider), expires_in: refresh_deduplication_window) do
      price = yield
      unless price.is_a?(CurrentMarketPrice) && price.provider == normalized_provider
        raise CurrentMarketPrice::InvalidValue, "provider does not match refresh"
      end

      write(instrument:, price:)
      price.to_cache_payload
    end

    read(instrument:, provider: normalized_provider)
  end

  private

  attr_reader :cache, :fresh_for, :refresh_deduplication_window, :clock

  def cache_key(instrument:, provider:)
    instrument_id = instrument.id
    raise ArgumentError, "instrument must be persisted" unless instrument_id

    "localfolio:current_market_price:v#{CACHE_VERSION}:#{provider}:instrument:#{instrument_id}"
  end

  def refresh_key(instrument:, provider:)
    "#{cache_key(instrument:, provider:)}:refresh"
  end

  def entry_for(price)
    status = price.stale?(at: clock.call, fresh_for:) ? :stale : :fresh
    Entry.new(price:, status:)
  end

  def missing_entry
    Entry.new(price: nil, status: :missing)
  end
end
