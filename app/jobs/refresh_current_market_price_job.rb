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

  def self.enqueue_for(instrument:, force: false, batch_scope: nil, batch_run_id: nil, lease_token: nil, lease_target: nil)
    cache = Rails.cache
    marker_key = deduplication_key(instrument)
    unless cache.write(marker_key, true, expires_in: DEDUPLICATION_WINDOW, unless_exist: true)
      instrument_event(:coalesced, instrument:)
      return COALESCED
    end

    job = if batch_scope
      perform_later(instrument, force:, batch_scope:, batch_run_id:, lease_token:, lease_target:)
    elsif force
      perform_later(instrument, force: true)
    else
      perform_later(instrument)
    end
    if job
      instrument_event(:enqueued, instrument:)
      return job
    end

    cache.delete(marker_key)
    nil
  rescue
    cache.delete(marker_key)
    raise
  end

  def self.refresh_scope(instrument)
    "current_market_price:#{instrument.id}"
  end

  def perform(instrument, force: false, batch_scope: nil, batch_run_id: nil, lease_token: nil, lease_target: nil)
    retry_scheduled = false
    executed = false
    job_class = self.class
    refresh_scope = job_class.refresh_scope(instrument)
    marker_key = job_class.deduplication_key(instrument)
    return if batch_scope && !batch_active?(batch_scope, batch_run_id)

    RefreshStatus::Tracker.perform(scope: refresh_scope, run_id: batch_run_id) do
      executed = true
      instrument_event(:attempted, instrument:)
      request_throttle.wait!(instrument:)
      market_price_service.refresh(instrument:, force:)
      refresh_exchange_rate(instrument:, force:)
      instrument_event(:succeeded, instrument:)
    end
  rescue MarketPrice::ProviderFailure, MarketPrice::CurrencyMismatch, MarketPrice::UnsupportedInstrument => error
    scheduled_delay = retry_provider_failure(error) if error.is_a?(MarketPrice::ProviderFailure)
    retry_scheduled = scheduled_delay
    if scheduled_delay
      RefreshStatus::Tracker.enqueue(scope: refresh_scope, run_id: batch_run_id)
      instrument_event(:retried, instrument:, wait_seconds: scheduled_delay.to_i)
    else
      report_failure(error, instrument:)
    end
  ensure
    Rails.cache.delete(marker_key) unless retry_scheduled
    broadcast_current(instrument)
    advance_batch(batch_scope, batch_run_id) if batch_scope && executed && !retry_scheduled
    release_lease(lease_token, lease_target) unless retry_scheduled
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
    base_currency = instrument.currency
    reporting_currencies_for(instrument:).each do |reporting_currency|
      next if base_currency == reporting_currency

      exchange_rate_service.refresh(
        base_currency:,
        quote_currency: reporting_currency,
        force:
      )
    end
  rescue ExchangeRate::InvalidValue => error
    report(error, instrument:)
  end

  def reporting_currencies_for(instrument:)
    users = if Caramelo::AccountMode.multi?
      user_ids = Trade.where(instrument:).pluck(:user_id) + CorporateAction.where(instrument:).pluck(:user_id)
      User.where(id: user_ids.uniq)
    else
      User.where(id: User.default_owner.id)
    end
    currencies = users.distinct.pluck(:reporting_currency)
    currencies.presence || User.distinct.pluck(:reporting_currency)
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

  def report_failure(error, instrument:)
    instrument_event(:failed, instrument:, error: error.class.name)
    report(error, instrument:)
  end

  def release_lease(token, target_attributes)
    return unless token && target_attributes

    MarketData::RecoveryLease.release(
      target: MarketData::Target.new(**target_attributes.symbolize_keys), token:
    )
  end

  def retry_provider_failure(error)
    return false unless error.retryable? && executions < MAX_RETRY_ATTEMPTS

    delay = retry_delay(error)
    retry_job wait: delay
    delay
  end

  def retry_delay(error)
    multiplier = 1 + (retry_random * RETRY_JITTER)
    retry_after = error.retry_after.to_s
    base_delay = if retry_after.match?(/\A\d+\z/)
      retry_after.to_i.seconds
    else
      retry_at = Time.httpdate(retry_after)
      [ retry_at - Time.current, 0.seconds ].max
    end

    [ base_delay * multiplier, MAX_RETRY_DELAY ].min
  rescue ArgumentError
    DEFAULT_RETRY_DELAY * multiplier
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
    "caramelo:market_price:refresh:#{instrument.id}"
  end
end
