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
    # A preference change during a long backfill must not mix target currencies.
    @reporting_currencies = reporting_currencies_for(backfill.instrument, backfill:)
    @publication_contexts = {}
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

  attr_reader :reporting_currencies

  def date_ranges(from_date, to_date)
    (from_date..to_date).each_slice(BATCH_SIZE).map { |dates| [ dates.first, dates.last ] }
  end

  def import_daily_closing_prices(instrument, from:, to:)
    request_throttle.wait!(instrument:)
    fence, generation = publication_context_for(instrument:)
    daily_closing_price_importer.call(
      instrument:, from:, to:, enqueue_performance_rebuild: false,
      fence:, generation:
    )
  end

  def import_historical_exchange_rates(currency, from:, to:)
    reporting_currencies.each do |reporting_currency|
      next if currency == reporting_currency

      request_throttle.wait!
      fence, generation = publication_context_for(base_currency: currency, quote_currency: reporting_currency)
      historical_exchange_rate_importer.call(
        base_currency: currency, quote_currency: reporting_currency, from:, to:,
        enqueue_performance_rebuild: false, fence:, generation:
      )
    end
  end

  def publication_fence_for(instrument: nil, base_currency: nil, quote_currency: nil)
    target = if instrument
      MarketData::Target.new(kind: :daily_closing_prices, record_id: instrument.id,
        provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier)
    else
      MarketData::Target.new(kind: :historical_exchange_rates, base_currency:, quote_currency:,
        provider: MarketData::YahooFinance::FX_CONFIGURATION.identifier)
    end
    MarketData::PublicationFence.new(target:)
  end

  def publication_context_for(instrument: nil, base_currency: nil, quote_currency: nil)
    key = if instrument
      [ :instrument, instrument.id ]
    else
      [ :exchange_rate, base_currency, quote_currency ]
    end
    @publication_contexts[key] ||= begin
      fence = publication_fence_for(instrument:, base_currency:, quote_currency:)
      [ fence, fence.capture ]
    end
  end

  def reporting_currencies_for(instrument, backfill: nil)
    return [ User.default_owner.reporting_currency ] if Caramelo::AccountMode.single?

    if backfill
      currencies = affected_users(backfill).distinct.pluck(:reporting_currency)
      currencies.concat(affected_instrument_targets(backfill).map(&:last))
      return currencies.uniq.presence || User.distinct.pluck(:reporting_currency)
    end

    user_ids = Trade.where(instrument:).pluck(:user_id) + CorporateAction.where(instrument:).pluck(:user_id)
    currencies = User.where(id: user_ids.uniq).distinct.pluck(:reporting_currency)
    currencies.presence || User.distinct.pluck(:reporting_currency)
  end

  def enqueue_performance_rebuild(backfill, from:)
    affected_users(backfill).find_each do |user|
      Performance::ObservationInvalidator.enqueue(user:, from:)
    end

    affected_instrument_targets(backfill).each do |user, instrument, reporting_currency|
      Performance::ObservationInvalidator.enqueue_instrument(
        user:, instrument:, reporting_currency:, from:
      )
    end
  end

  def affected_users(backfill)
    trade_user_ids = Trade.where(instrument: backfill.instrument).or(
      Trade.where(currency: backfill.currency)
    ).or(
      Trade.where(settlement_currency: backfill.currency)
    ).distinct.pluck(:user_id)
    action_user_ids = CorporateAction.effective_on_or_before(Date.current).joins(:instrument)
      .where(
        "corporate_actions.instrument_id = :instrument_id OR corporate_actions.currency = :currency " \
          "OR instruments.currency = :currency",
        instrument_id: backfill.instrument_id, currency: backfill.currency
      ).distinct.pluck(:user_id)

    User.where(id: (trade_user_ids + action_user_ids).uniq)
  end

  def affected_instrument_targets(backfill)
    affected_users(backfill).flat_map do |user|
      trades = user.trades.where(traded_on: ..Date.current).includes(:instrument).to_a
      actions = user.corporate_actions.effective_on_or_before(Date.current).includes(:instrument).to_a
      activity_by_instrument = (trades + actions).group_by(&:instrument)

      activity_by_instrument.filter_map do |instrument, activity|
        trade_currencies = activity.filter_map { |record| record.settlement_currency if record.is_a?(Trade) }
        action_currencies = activity.filter_map do |record|
          record.currency || record.instrument.currency if record.is_a?(CorporateAction)
        end
        price_affected = instrument.id == backfill.instrument_id
        dependency_affected = ([ instrument.currency ] + trade_currencies + action_currencies)
          .include?(backfill.currency)
        next unless price_affected || dependency_affected

        reporting_currencies_for_instrument(user:, instrument:).filter_map do |reporting_currency|
          next if !price_affected && reporting_currency == backfill.currency

          [ user, instrument, reporting_currency ]
        end
      end
    end.flatten(1).uniq { |user, instrument, currency| [ user.id, instrument.id, currency ] }
  end

  def reporting_currencies_for_instrument(user:, instrument:)
    materialized_currencies = user.instrument_performance_materializations
      .where(instrument:).distinct.pluck(:reporting_currency)
    (materialized_currencies + [ instrument.currency, user.reporting_currency ]).uniq
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
