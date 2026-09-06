class ExchangeRateCache
  CACHE_VERSION = 1
  DEFAULT_FRESH_FOR = 30.minutes

  Lookup = Data.define(:exchange_rate, :status) do
    def fresh? = status == :fresh
    def stale? = status == :stale
    def missing? = status == :missing
    def same_currency? = status == :same_currency
    def refresh_needed? = !fresh? && !same_currency?
  end

  def initialize(cache: Rails.cache, fresh_for: DEFAULT_FRESH_FOR)
    raise ArgumentError, "freshness must be positive" unless fresh_for.positive?

    @cache = cache
    @fresh_for = fresh_for
  end

  def read(base_currency:, quote_currency:, provider:)
    key = cache_key(base_currency:, quote_currency:, provider:)
    payload = cache.read(key)
    return missing_lookup unless payload

    exchange_rate = from_cache_payload(payload)
    unless exchange_rate.base_currency == base_currency && exchange_rate.quote_currency == quote_currency && exchange_rate.provider == provider
      raise ExchangeRate::InvalidPayload, "rate does not match cache key"
    end

    lookup_for(exchange_rate)
  rescue ExchangeRate::InvalidPayload
    cache.delete(key)
    missing_lookup
  end

  def write(exchange_rate:)
    unless exchange_rate.is_a?(ExchangeRate::Rate)
      raise ArgumentError, "exchange rate must be an ExchangeRate::Rate"
    end

    cache.write(
      cache_key(
        base_currency: exchange_rate.base_currency,
        quote_currency: exchange_rate.quote_currency,
        provider: exchange_rate.provider
      ),
      exchange_rate.to_cache_payload
    )
    lookup_for(exchange_rate)
  end

  def refresh(base_currency:, quote_currency:, provider:, force: false, fence: nil)
    generation = fence&.capture
    current_lookup = read(base_currency:, quote_currency:, provider:)
    return current_lookup if current_lookup.fresh? && !force

    exchange_rate = yield
    return write(exchange_rate:) unless fence

    result = nil
    return current_lookup if fence.publish(generation) { result = write(exchange_rate:) } == :superseded

    result
  end

  private

  attr_reader :cache, :fresh_for

  def from_cache_payload(payload)
    raise ExchangeRate::InvalidPayload, "payload must be a hash" unless payload.is_a?(Hash)

    rate = BigDecimal(payload.fetch("rate"))
    raise ExchangeRate::InvalidPayload, "rate must be finite and positive" unless rate.finite? && rate.positive?

    ExchangeRate::Rate.new(
      base_currency: payload.fetch("base_currency"),
      quote_currency: payload.fetch("quote_currency"),
      rate:,
      observed_at: Time.iso8601(payload.fetch("observed_at")),
      fetched_at: Time.iso8601(payload.fetch("fetched_at")),
      provider: payload.fetch("provider")
    )
  rescue KeyError, TypeError, ArgumentError => error
    raise ExchangeRate::InvalidPayload, error.message
  end

  def cache_key(base_currency:, quote_currency:, provider:)
    "localfolio:exchange_rate:v#{CACHE_VERSION}:#{provider}:#{base_currency}:#{quote_currency}"
  end

  def lookup_for(exchange_rate)
    status = exchange_rate.stale?(fresh_for:) ? :stale : :fresh
    Lookup.new(exchange_rate:, status:)
  end

  def missing_lookup
    Lookup.new(exchange_rate: nil, status: :missing)
  end
end
