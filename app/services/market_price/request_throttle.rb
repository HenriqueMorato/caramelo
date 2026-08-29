module MarketPrice
  class RequestThrottle
    CACHE_KEY = "localfolio:market_price:yahoo_finance:last_request_at"
    DEFAULT_INTERVAL = 1.second

    def initialize(cache: Rails.cache, interval: configured_interval, clock: -> { Time.current }, sleeper: Kernel.method(:sleep))
      raise ArgumentError, "interval must not be negative" if interval.negative?

      @cache = cache
      @interval = interval
      @clock = clock
      @sleeper = sleeper
    end

    def wait!(instrument: nil)
      now = clock.call
      last_request_at = cache.read(CACHE_KEY)
      delay = interval - (now - last_request_at) if last_request_at
      if delay&.positive?
        ActiveSupport::Notifications.instrument(
          "market_price.refresh",
          { event: :throttled, provider: "yahoo_finance", delay_seconds: delay, instrument_id: instrument&.id }
        ) { sleeper.call(delay) }
      end
      cache.write(CACHE_KEY, clock.call)
    end

    private

    attr_reader :cache, :interval, :clock, :sleeper

    def configured_interval
      seconds = Float(ENV.fetch("YAHOO_FINANCE_MINIMUM_INTERVAL_SECONDS", DEFAULT_INTERVAL.to_f))
      raise ArgumentError, "interval must be positive" unless seconds.positive?

      seconds.seconds
    rescue ArgumentError, TypeError
      raise ArgumentError, "YAHOO_FINANCE_MINIMUM_INTERVAL_SECONDS must be positive"
    end
  end
end
