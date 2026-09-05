module MarketData
  class Recovery
    COOLDOWN = 5.minutes
    COOLDOWN_PREFIX = "localfolio:market_data:recovery:cooldown"
    BATCH_SCOPE_PREFIX = "market_data_recovery"

    Result = Data.define(:status, :target, :batch_scope, :batch_run_id) do
      def queued? = status == :queued
      def throttled? = status == :throttled
      def unsupported? = status == :unsupported
    end

    HANDLERS = {
      current_price: MarketData::Recoveries::CurrentPrice,
      current_exchange_rate: MarketData::Recoveries::CurrentExchangeRate,
      daily_closing_prices: MarketData::Recoveries::DailyClosingPrices,
      historical_exchange_rates: MarketData::Recoveries::HistoricalExchangeRates,
      benchmark_observations: MarketData::Recoveries::BenchmarkObservations
    }.freeze

    def self.call(target:, range: nil, owner: User.owner, cache: Rails.cache, handlers: HANDLERS)
      new(target:, range:, owner:, cache:, handlers:).call
    end

    def self.available?(target:, cache: Rails.cache)
      !cache.exist?(cooldown_key(target))
    end

    def self.cooldown_key(target)
      "#{COOLDOWN_PREFIX}:#{target.scope}"
    end

    def initialize(target:, range:, owner:, cache:, handlers:)
      @target = target
      @range = range
      @owner = owner
      @cache = cache
      @handlers = handlers
    end

    def call
      handler = handlers[target.kind]
      return result(:unsupported) unless handler

      token = acquire_cooldown
      return result(:throttled) unless token

      batch = RefreshStatus::Tracker.enqueue(scope: batch_scope, total_count: 1)
      handler_result = handler.call(
        target:, range:, batch_scope:, batch_run_id: batch.run_id, owner:
      )

      if handler_result.nil? || handler_result == RefreshCurrentMarketPriceJob::COALESCED
        RefreshStatus::Tracker.advance(batch)
        release_cooldown(token)
        return result(handler_result.nil? ? :unsupported : :queued, batch:)
      end

      result(:queued, batch:)
    rescue StandardError => error
      release_cooldown(token)
      RefreshStatus::Tracker.record_failure(batch, error) if batch
      raise
    end

    private

    attr_reader :target, :range, :owner, :cache, :handlers

    def batch_scope
      @batch_scope ||= "#{BATCH_SCOPE_PREFIX}:#{owner.id}:#{SecureRandom.uuid}"
    end

    def result(status, batch: nil)
      Result.new(
        status:,
        target:,
        batch_scope: batch&.scope || batch_scope,
        batch_run_id: batch&.run_id
      )
    end

    def acquire_cooldown
      token = SecureRandom.uuid
      acquired = cache.write(
        self.class.cooldown_key(target), token,
        expires_in: COOLDOWN, unless_exist: true
      )
      token if acquired
    end

    def release_cooldown(token)
      key = self.class.cooldown_key(target)
      cache.delete(key) if token && cache.read(key) == token
    end
  end
end
