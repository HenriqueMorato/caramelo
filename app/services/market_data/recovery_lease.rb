module MarketData
  # A short-lived distributed lease prevents duplicate recovery jobs for one
  # target while allowing unrelated instruments and pairs to proceed.
  class RecoveryLease
    TTL = 30.minutes
    PREFIX = "localfolio:market_data:recovery_lease"

    Lease = Data.define(:target, :token, :expires_at) do
      def active?
        expires_at && expires_at > Time.current
      end
    end

    def self.acquire(target:, cache: Rails.cache)
      token = SecureRandom.uuid
      acquired = cache.write(key(target), { token:, expires_at: TTL.from_now.iso8601 }, expires_in: TTL, unless_exist: true)
      acquired ? Lease.new(target:, token:, expires_at: TTL.from_now) : nil
    end

    def self.current(target:, cache: Rails.cache)
      payload = cache.read(key(target))
      return unless payload.is_a?(Hash) && payload[:token]

      Lease.new(target:, token: payload[:token], expires_at: Time.iso8601(payload[:expires_at].to_s))
    rescue ArgumentError, TypeError
      nil
    end

    def self.release(target:, token:, cache: Rails.cache)
      lease = current(target:, cache:)
      cache.delete(key(target)) if lease&.token == token
    end

    def self.key(target)
      "#{PREFIX}:#{target.publication_scope}"
    end

    private_class_method :key
  end
end
