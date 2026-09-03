module MarketPrice
  class ManualRefresh
    REFRESH_SCOPE = RefreshStatus::MARKET_PRICE_SCOPE
    COOLDOWN = 5.minutes
    COOLDOWN_KEY = "localfolio:manual_market_price_refresh:last_started_at"

    def self.call(**arguments)
      new(**arguments).call
    end

    def self.available?(clock: -> { Time.current })
      new(clock:).available?
    end

    def initialize(enqueuer: RefreshEnqueuer.new, clock: -> { Time.current })
      @enqueuer = enqueuer
      @clock = clock
    end

    def call
      return false unless available?

      Rails.cache.write(COOLDOWN_KEY, clock.call)
      instruments = traded_instruments.to_a
      batch = RefreshStatus::Tracker.enqueue(scope: REFRESH_SCOPE, total_count: instruments.size)
      instruments.each do |instrument|
        result = enqueuer.enqueue(instrument:, batch_scope: REFRESH_SCOPE, batch_run_id: batch.run_id)
        advance_batch if result.nil? || result == RefreshCurrentMarketPriceJob::COALESCED
      end
      true
    end

    def available?
      last_started_at = Rails.cache.read(COOLDOWN_KEY)
      last_started_at.nil? || clock.call - last_started_at >= COOLDOWN
    end

    private

    attr_reader :enqueuer, :clock

    def traded_instruments
      Instrument.where(id: Trade.where(user: User.owner).select(:instrument_id))
    end

    def advance_batch
      batch = RefreshStatus::State.read(REFRESH_SCOPE)
      RefreshStatus::Tracker.advance(batch) if batch&.active?
    end
  end
end
