class RefreshCurrentMarketPriceJob < ApplicationJob
  queue_as :market_prices

  limits_concurrency key: ->(instrument, *) { instrument }, duration: 2.minutes, on_conflict: :block
  discard_on ActiveJob::DeserializationError

  def perform(instrument, force: false)
    market_price_service.refresh(instrument:, force:)
  rescue MarketPrice::ProviderFailure, MarketPrice::CurrencyMismatch,
    MarketPrice::UnsupportedInstrument => error
    report(error, instrument:)
  ensure
    broadcast_current(instrument)
  end

  private

  def market_price_service
    MarketPrice::Service.default
  end

  def market_price_broadcaster
    MarketPrice::Broadcaster.new
  end

  def broadcast_current(instrument)
    market_price_broadcaster.current(instrument:)
  rescue => error
    report(error, instrument:)
  end

  def report(error, instrument:)
    Rails.error.report(error, handled: true, context: { instrument_id: instrument.id })
  end
end
