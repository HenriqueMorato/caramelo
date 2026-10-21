module MarketData
  class Recovery
    COOLDOWN = 5.minutes
    COOLDOWN_PREFIX = "caramelo:market_data:recovery:cooldown"
    BATCH_SCOPE_PREFIX = "market_data_recovery"
    ASYNC = :async

    Result = Data.define(:status, :target, :batch_scope, :batch_run_id) do
      def queued? = status == :queued
      def throttled? = status == :throttled
      def unsupported? = status == :unsupported
      def already_running? = status == :already_running
    end

    HANDLERS = {
      current_price: MarketData::Recoveries::CurrentPrice,
      current_exchange_rate: MarketData::Recoveries::CurrentExchangeRate,
      daily_closing_prices: MarketData::Recoveries::DailyClosingPrices,
      historical_exchange_rates: MarketData::Recoveries::HistoricalExchangeRates,
      benchmark_observations: MarketData::Recoveries::BenchmarkObservations,
      portfolio_performance: MarketData::Recoveries::PerformanceObservations,
      instrument_performance: MarketData::Recoveries::PerformanceObservations,
      corporate_action_imports: MarketData::Recoveries::CorporateActionImports
    }.freeze

    def self.call(target:, range: nil, owner: User.default_owner, cache: Rails.cache, handlers: HANDLERS,
      replacement: false)
      new(target:, range:, owner:, cache:, handlers:, replacement:).call
    end

    def self.available?(target:, owner: nil, cache: Rails.cache)
      !cache.exist?(cooldown_key(target, owner:))
    end

    def self.cooldown_key(target, owner: nil)
      owner_scope = if owner && performance_target?(target)
        ":owner:#{owner.id}"
      end
      "#{COOLDOWN_PREFIX}:#{target.scope}#{owner_scope}"
    end

    def initialize(target:, range:, owner:, cache:, handlers:, replacement: false)
      @target = target
      @range = range
      @owner = owner
      @cache = cache
      @handlers = handlers
      @replacement = replacement
    end

    def call
      handler = handlers[target.kind]
      return result(:unsupported) unless handler
      validate_range!

      lease = RecoveryLease.acquire(target:, owner:, cache:)
      return result(:already_running) unless lease

      token = acquire_cooldown
      unless token
        RecoveryLease.release(target:, owner:, token: lease.token, cache:)
        return result(:throttled)
      end

      batch = RefreshStatus::Tracker.enqueue(scope: batch_scope, total_count: 1)
      arguments = {
        target:, range:, batch_scope:, batch_run_id: batch.run_id, owner:, lease_token: lease.token
      }
      handler_result = if replacement
        PublicationFence.new(target:, cache:).advance { handler.call(**arguments) }
      else
        handler.call(**arguments)
      end

      if handler_result.nil? || handler_result == RefreshCurrentMarketPriceJob::COALESCED || handler_result == ASYNC
        RefreshStatus::Tracker.advance(batch)
        release_cooldown(token) unless handler_result == ASYNC
        RecoveryLease.release(target:, owner:, token: lease.token, cache:)
        broadcast_health if handler_result == RefreshCurrentMarketPriceJob::COALESCED && broadcast_after_enqueue?
        return result(handler_result.nil? ? :unsupported : :queued, batch:)
      end

      broadcast_health
      result(:queued, batch:)
    rescue StandardError => error
      release_cooldown(token)
      RecoveryLease.release(target:, owner:, token: lease.token, cache:) if lease
      RefreshStatus::Tracker.record_failure(batch, error) if batch
      raise
    end

    private

    attr_reader :target, :range, :owner, :cache, :handlers, :replacement

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
        self.class.cooldown_key(target, owner:), token,
        expires_in: COOLDOWN, unless_exist: true
      )
      token if acquired
    end

    def release_cooldown(token)
      key = self.class.cooldown_key(target, owner:)
      cache.delete(key) if token && cache.read(key) == token
    end

    def validate_range!
      return unless range
      return if range.is_a?(Range) && range.begin.is_a?(Date) && range.end.is_a?(Date) &&
        (range.end - range.begin).to_i <= Performance::HistoricalDependencyFetcher::MAX_RANGE_DAYS

      raise ArgumentError, "recovery range exceeds the maximum supported span"
    end

    def self.performance_target?(target)
      %i[portfolio_performance instrument_performance].include?(target.kind)
    end

    private_class_method :performance_target?

    def broadcast_after_enqueue?
      !%i[portfolio_performance instrument_performance].include?(target.kind)
    end

    def broadcast_health
      MarketData::HealthReportBroadcaster.refresh
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { source: "market_data_recovery_health_broadcast" })
    end
  end
end
