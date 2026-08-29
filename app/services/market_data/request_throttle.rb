module MarketData
  class RequestThrottle
    def initialize(provider:, interval:, cache: Rails.cache, clock: -> { Time.current }, sleeper: Kernel.method(:sleep))
      @provider = provider.to_s
      raise ArgumentError, "provider is required" if @provider.empty?
      raise ArgumentError, "interval must not be negative" if interval.negative?

      @cache = cache
      @interval = interval
      @clock = clock
      @sleeper = sleeper
    end

    def wait!(instrument: nil)
      now = clock.call
      last_request_at = cache.read(cache_key)
      delay = interval - (now - last_request_at) if last_request_at
      if delay&.positive?
        ActiveSupport::Notifications.instrument(
          notification_name,
          { event: :throttled, provider:, delay_seconds: delay, instrument_id: instrument&.id }
        ) { sleeper.call(delay) }
      end
      cache.write(cache_key, clock.call)
    end

    private

    attr_reader :provider, :cache, :interval, :clock, :sleeper

    def cache_key
      "localfolio:market_data:#{provider}:last_request_at"
    end

    def notification_name
      "market_data.#{provider}.request"
    end
  end
end
