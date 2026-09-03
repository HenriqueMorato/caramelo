class BackfillHistoricalMarketDataJob < ApplicationJob
  queue_as :market_prices

  BATCH_SIZE = 90
  RETRY_ATTEMPTS = 3

  limits_concurrency key: ->(*) { "provider:yahoo_finance" }, duration: 2.minutes, on_conflict: :block
  discard_on ActiveJob::DeserializationError
  retry_on MarketData::YahooFinance::TransportError, MarketData::YahooFinance::RateLimited,
    MarketData::YahooFinance::ProviderUnavailable, wait: :polynomially_longer, attempts: RETRY_ATTEMPTS do |job, error|
      job.discard_backfill(error)
    end

  def perform(backfill)
    RefreshStatus::Tracker.perform(scope: "historical_backfill:#{backfill.id}") do
      from_date, generation = backfill.with_lock { [ backfill.from_date, backfill.generation ] }

      date_ranges(from_date, Date.current).each do |from, to|
        import_daily_closing_prices(backfill.instrument, from:, to:)
        import_historical_exchange_rates(backfill.currency, from:, to:)
      end

      enqueue_performance_rebuild(backfill, from: from_date)
      complete(backfill, generation:)
    end
  rescue MarketData::YahooFinance::InvalidResponse, MarketData::YahooFinance::Unauthorized,
    MarketData::YahooFinance::SymbolNotFound, MarketData::YahooFinance::InvalidIdentifier,
    MarketData::YahooFinance::UnsupportedExchange => error
    discard_backfill(error, backfill:)
  end

  def discard_backfill(error, backfill: arguments.first)
    Rails.error.report(error, handled: true, context: { historical_data_backfill_id: backfill.id })
    backfill.destroy!
  end

  private

  def daily_closing_price_importer
    @daily_closing_price_importer ||= DailyClosingPrice::Importer.default
  end

  def historical_exchange_rate_importer
    @historical_exchange_rate_importer ||= HistoricalExchangeRate::Importer.default
  end

  def request_throttle
    @request_throttle ||= MarketData::YahooFinance::RequestThrottle.new
  end

  def reporting_currency
    Rails.configuration.x.local_folio.reporting_currency
  end

  def date_ranges(from_date, to_date)
    (from_date..to_date).each_slice(BATCH_SIZE).map { |dates| [ dates.first, dates.last ] }
  end

  def import_daily_closing_prices(instrument, from:, to:)
    request_throttle.wait!(instrument:)
    daily_closing_price_importer.call(
      instrument:, from:, to:, enqueue_performance_rebuild: false
    )
  end

  def import_historical_exchange_rates(currency, from:, to:)
    return if currency == reporting_currency

    request_throttle.wait!
    historical_exchange_rate_importer.call(
      base_currency: currency, quote_currency: reporting_currency, from:, to:,
      enqueue_performance_rebuild: false
    )
  end

  def enqueue_performance_rebuild(backfill, from:)
    affected_trades = Trade.where(instrument: backfill.instrument)
      .or(Trade.where(currency: backfill.currency))
    User.where(id: affected_trades.select(:user_id)).find_each do |user|
      Performance::ObservationInvalidator.enqueue(user:, from:)
    end
  end

  def complete(backfill, generation:)
    backfill.with_lock do
      if backfill.generation == generation
        backfill.destroy!
      else
        self.class.perform_later(backfill)
      end
    end
  end
end
