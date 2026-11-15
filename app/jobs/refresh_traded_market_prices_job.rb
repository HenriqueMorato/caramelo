class RefreshTradedMarketPricesJob < ApplicationJob
  queue_as :market_prices

  DEDUPLICATION_WINDOW = 5.minutes
  COORDINATOR_CONCURRENCY_KEY = "market_data:refresh_traded_market_prices"

  class EnqueueFailure < RuntimeError; end

  # Recurring schedules catch up after downtime; never replay duplicate coordinators.
  limits_concurrency key: ->(*) { COORDINATOR_CONCURRENCY_KEY }, duration: DEDUPLICATION_WINDOW, on_conflict: :discard

  def self.enqueue_for
    return :coalesced unless Rails.cache.write(deduplication_key, true, expires_in: DEDUPLICATION_WINDOW, unless_exist: true)

    job = perform_later
    return job if job

    Rails.cache.delete(deduplication_key)
    nil
  rescue
    Rails.cache.delete(deduplication_key)
    raise
  end

  def perform
    instruments = traded_instruments
    instrument_ids = instruments.pluck(:id)
    existing_refresh = RefreshStatus::State.read(RefreshStatus::MARKET_PRICE_SCOPE)
    RefreshStatus::Tracker.perform(
      scope: RefreshStatus::MARKET_PRICE_SCOPE,
      total_count: instrument_ids.length,
      tracked_items: instrument_ids,
      preserve_progress: existing_refresh&.active? && !existing_refresh.tracked_items.nil?
    ) do |refresh|
      instruments.find_each do |instrument|
        progress_key = instrument.id.to_s
        unless market_price_service.supports?(instrument:)
          ActiveSupport::Notifications.instrument(
            "market_price.refresh",
            event: :skipped,
            provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier,
            instrument_id: instrument.id
          )
          RefreshStatus::Tracker.advance(refresh, key: progress_key)
          next
        end

        lookup = market_price_service.read(instrument:)
        if lookup&.refresh_needed?
          break if enqueue_instrument_refresh(instrument:, refresh:) == :failed
        else
          RefreshStatus::Tracker.advance(refresh, key: progress_key)
        end
      end
    end
  ensure
    Rails.cache.delete(self.class.deduplication_key)
  end

  private

  def enqueue_instrument_refresh(instrument:, refresh:)
    scope = RefreshCurrentMarketPriceJob.refresh_scope(instrument)
    state = RefreshStatus::State.read(scope)
    if state&.run_id == refresh.run_id
      if state.status == "succeeded"
        RefreshStatus::Tracker.advance(refresh, key: instrument.id)
        return
      end
      if state.status == "failed"
        error_message = state.error_message.presence || "#{instrument.ticker} market-price refresh failed"
        RefreshStatus::Tracker.record_failure(refresh, RuntimeError.new(error_message))
        return :failed
      end
    else
      RefreshStatus::Tracker.enqueue(scope:, run_id: refresh.run_id, supersede: true)
    end

    result = RefreshCurrentMarketPriceJob.enqueue_for(
      instrument:, batch_scope: RefreshStatus::MARKET_PRICE_SCOPE, batch_run_id: refresh.run_id
    )
    raise EnqueueFailure, "could not enqueue #{instrument.ticker} market-price refresh" unless result
  end

  def market_price_service
    MarketPrice::Service.default
  end

  def traded_instruments
    trades = Caramelo::AccountMode.multi? ? Trade.all : Trade.where(user: User.default_owner)
    Instrument.where(
      id: trades.distinct.select(:instrument_id)
    )
  end

  def self.deduplication_key
    "caramelo:market_price:refresh_traded"
  end
end
