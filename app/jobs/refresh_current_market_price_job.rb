class RefreshCurrentMarketPriceJob < ApplicationJob
  queue_as :market_prices

  DEDUPLICATION_WINDOW = 2.minutes
  COALESCED = :coalesced
  MAX_RETRY_ATTEMPTS = 3
  MAX_RETRY_DELAY = 5.minutes
  DEFAULT_RETRY_DELAY = 30.seconds
  RETRY_JITTER = 0.1

  limits_concurrency key: ->(*) { "provider:yahoo_finance" }, duration: 2.minutes, on_conflict: :block
  discard_on ActiveJob::DeserializationError

  def self.enqueue_for(instrument:, force: false, batch_scope: nil, batch_run_id: nil)
    marker_key = deduplication_key(instrument)
    unless Rails.cache.write(marker_key, true, expires_in: DEDUPLICATION_WINDOW, unless_exist: true)
      instrument_event(:coalesced, instrument:)
      return COALESCED
    end

    job = if batch_scope
      perform_later(instrument, force:, batch_scope:, batch_run_id:)
    elsif force
      perform_later(instrument, force: true)
    else
      perform_later(instrument)
    end
    if job
      instrument_event(:enqueued, instrument:)
      return job
    end

    Rails.cache.delete(marker_key)
    nil
  rescue
    Rails.cache.delete(marker_key)
    raise
  end

  def self.refresh_scope(instrument)
    "current_market_price:#{instrument.id}"
  end

  def perform(instrument, force: false, batch_scope: nil, batch_run_id: nil)
    retry_scheduled = false
    return if batch_scope && !batch_active?(batch_scope, batch_run_id)

    RefreshStatus::Tracker.perform(scope: batch_scope || self.class.refresh_scope(instrument),
      preserve_progress: batch_scope.present?, run_id: batch_run_id) do
      instrument_event(:attempted, instrument:)
      request_throttle.wait!(instrument:)
      market_price_service.refresh(instrument:, force:)
      refresh_exchange_rate(instrument:, force:)
      instrument_event(:succeeded, instrument:)
    end
  rescue MarketPrice::ProviderFailure => error
    scheduled_delay = retry_provider_failure(error)
    retry_scheduled = scheduled_delay
    if scheduled_delay
      RefreshStatus::Tracker.enqueue(scope: self.class.refresh_scope(instrument))
      instrument_event(:retried, instrument:, wait_seconds: scheduled_delay.to_i)
    else
      instrument_event(:failed, instrument:, error: error.class.name)
      report(error, instrument:)
    end
  rescue MarketPrice::CurrencyMismatch, MarketPrice::UnsupportedInstrument => error
    instrument_event(:failed, instrument:, error: error.class.name)
    report(error, instrument:)
  ensure
    Rails.cache.delete(self.class.deduplication_key(instrument)) unless retry_scheduled
    broadcast_current(instrument)
    advance_batch(batch_scope, batch_run_id) if batch_scope && !retry_scheduled
  end

  private

  def market_price_service
    MarketPrice::Service.default
  end

  def request_throttle
    MarketData::YahooFinance::RequestThrottle.new
  end

  def market_price_broadcaster
    MarketPrice::Broadcaster.new
  end

  def exchange_rate_service
    ExchangeRate::Service.default
  end

  def refresh_exchange_rate(instrument:, force:)
    reporting_currency = User.owner.reporting_currency
    return if instrument.currency == reporting_currency

    exchange_rate_service.refresh(
      base_currency: instrument.currency,
      quote_currency: reporting_currency,
      force:
    )
  rescue ExchangeRate::InvalidValue => error
    report(error, instrument:)
  end

  def broadcast_current(instrument)
    market_price_broadcaster.current(instrument:)
  rescue => error
    report(error, instrument:)
  end

  def advance_batch(batch_scope, batch_run_id)
    batch = RefreshStatus::State.read(batch_scope)
    RefreshStatus::Tracker.advance(batch) if batch&.active? && batch.run_id == batch_run_id
  end

  def batch_active?(batch_scope, batch_run_id)
    batch = RefreshStatus::State.read(batch_scope)
    batch&.active? && batch.run_id == batch_run_id
  end

  def report(error, instrument:)
    Rails.error.report(error, handled: true, context: { instrument_id: instrument.id })
  end

  def retry_provider_failure(error)
    return false unless error.retryable? && executions < MAX_RETRY_ATTEMPTS

    delay = retry_delay(error)
    retry_job wait: delay
    delay
  end

  def retry_delay(error)
    retry_after = error.retry_after.to_s
    base_delay = if retry_after.match?(/\A\d+\z/)
      retry_after.to_i.seconds
    else
      retry_at = Time.httpdate(retry_after)
      [ retry_at - Time.current, 0.seconds ].max
    end

    [ base_delay * (1 + (retry_random * RETRY_JITTER)), MAX_RETRY_DELAY ].min
  rescue ArgumentError
    DEFAULT_RETRY_DELAY * (1 + (retry_random * RETRY_JITTER))
  end

  def retry_random
    Kernel.rand
  end

  def instrument_event(event, instrument:, **payload)
    self.class.instrument_event(event, instrument:, **payload)
  end

  def self.instrument_event(event, instrument:, **payload)
    ActiveSupport::Notifications.instrument(
      "market_price.refresh",
      {
        event:,
        provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier,
        instrument_id: instrument.id
      }.merge(payload)
    )
  end

  def self.deduplication_key(instrument)
    "localfolio:market_price:refresh:#{instrument.id}"
  end
end
