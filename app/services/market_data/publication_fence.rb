module MarketData
  class PublicationFence
    LOCK_RETRY_INTERVAL = 0.05.seconds
    LOCK_EXPIRY = 30.seconds

    def initialize(target:, cache: Rails.cache, sleeper: Kernel.method(:sleep))
      @target = target
      @cache = cache
      @sleeper = sleeper
    end

    def capture
      cache.read(generation_key) || initialize_generation
    end

    def publish(generation)
      with_lock do
        return :superseded unless cache.read(generation_key) == generation

        yield
        :published
      end
    end

    def advance
      with_lock do
        generation = SecureRandom.uuid
        cache.write(generation_key, generation)
        yield generation
        generation
      end
    end

    private

    attr_reader :target, :cache, :sleeper

    def initialize_generation
      candidate = SecureRandom.uuid
      cache.write(generation_key, candidate, unless_exist: true)
      cache.read(generation_key) || candidate
    end

    def with_lock
      token = SecureRandom.uuid
      acquire_lock(token)
      yield
    ensure
      release_lock(token)
    end

    def acquire_lock(token)
      until cache.write(lock_key, token, expires_in: LOCK_EXPIRY, unless_exist: true)
        sleeper.call(LOCK_RETRY_INTERVAL)
      end
    end

    def release_lock(token)
      cache.delete(lock_key) if token && cache.read(lock_key) == token
    end

    def generation_key
      "caramelo:market_data:generation:#{target.publication_scope}"
    end

    def lock_key
      "#{generation_key}:lock"
    end
  end
end
