module MarketData
  class RequestThrottle
    LOCK_RETRY_INTERVAL = 0.05.seconds
    LOCK_EXPIRY = 30.seconds

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
      lock_token = SecureRandom.hex
      acquire_lock(lock_token)

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
    ensure
      release_lock(lock_token)
    end

    private

    attr_reader :provider, :cache, :interval, :clock, :sleeper

    def cache_key
      "caramelo:market_data:#{provider}:last_request_at"
    end

    def notification_name
      "market_data.#{provider}.request"
    end

    def lock_key
      "#{cache_key}:lock"
    end

    def acquire_lock(lock_token)
      until cache.write(lock_key, lock_token, expires_in: LOCK_EXPIRY, unless_exist: true)
        sleeper.call(LOCK_RETRY_INTERVAL)
      end
    end

    def release_lock(lock_token)
      cache.delete(lock_key) if cache.read(lock_key) == lock_token
    end
  end
end
