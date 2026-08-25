class CurrentMarketPriceCache
  CACHE_VERSION = 1
  DEFAULT_FRESH_FOR = 30.minutes

  Entry = Data.define(:current_market_price, :status) do
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

  def initialize(cache: Rails.cache, fresh_for: DEFAULT_FRESH_FOR)
    raise ArgumentError, "freshness must be positive" unless fresh_for.positive?

    @cache = cache
    @fresh_for = fresh_for
  end

  def read(instrument:, provider:)
    normalized_provider = CurrentMarketPrice.normalize_provider(provider)
    key = cache_key(instrument:, provider: normalized_provider)
    payload = cache.read(key)
    return missing_entry unless payload

    current_market_price = CurrentMarketPrice.from_cache_payload(payload)
    unless current_market_price.provider == normalized_provider
      raise CurrentMarketPrice::InvalidPayload, "provider does not match cache key"
    end
    unless current_market_price.currency == instrument.currency
      raise CurrentMarketPrice::InvalidPayload, "currency does not match instrument"
    end

    entry_for(current_market_price)
  rescue CurrentMarketPrice::InvalidPayload
    # Cached quotes are replaceable, so corrupt data is safer to discard.
    cache.delete(key)
    missing_entry
  end

  def write(instrument:, current_market_price:)
    unless current_market_price.is_a?(CurrentMarketPrice)
      raise ArgumentError, "current market price must be a CurrentMarketPrice"
    end
    unless current_market_price.currency == instrument.currency
      raise CurrentMarketPrice::InvalidValue, "currency does not match instrument"
    end

    # No expiry: the last known quote remains available as stale fallback.
    cache.write(
      cache_key(instrument:, provider: current_market_price.provider),
      current_market_price.to_cache_payload
    )
    entry_for(current_market_price)
  end

  def refresh(instrument:, provider:, force: false)
    provider = CurrentMarketPrice.normalize_provider(provider)
    current_entry = read(instrument:, provider:)
    return current_entry if current_entry.fresh? && !force

    current_market_price = yield
    unless current_market_price.is_a?(CurrentMarketPrice) && current_market_price.provider == provider
      raise CurrentMarketPrice::InvalidValue, "provider does not match refresh"
    end

    write(instrument:, current_market_price:)
  end

  private

  attr_reader :cache, :fresh_for

  def cache_key(instrument:, provider:)
    instrument_id = instrument.id
    raise ArgumentError, "instrument must be persisted" unless instrument_id

    "localfolio:current_market_price:v#{CACHE_VERSION}:#{provider}:instrument:#{instrument_id}"
  end

  def entry_for(current_market_price)
    status = current_market_price.stale?(fresh_for:) ? :stale : :fresh
    Entry.new(current_market_price:, status:)
  end

  def missing_entry
    Entry.new(current_market_price: nil, status: :missing)
  end
end
