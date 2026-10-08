class CaptureHistoricalExchangeRatesJob < ApplicationJob
  queue_as :market_prices

  def perform(rate_date: nil)
    # Snapshot once per execution, rather than changing pairs midway through a batch.
    @reporting_currency = User.owner.reporting_currency
    rate_date ||= TradingCalendar.previous_business_day

    currencies = performance_currencies
    RefreshStatus::Tracker.perform(scope: "historical_exchange_rates", total_count: currencies.length) do |refresh|
      currencies.each do |currency|
        next if HistoricalExchangeRate.exists?(
          base_currency: currency, quote_currency: reporting_currency,
          rate_date: rate_date, provider: HistoricalExchangeRate::Providers::YahooFinance::IDENTIFIER
        )

        throttle.wait!
        importer.call(
          base_currency: currency,
          quote_currency: reporting_currency,
          from: rate_date,
          to: rate_date,
          fence: publication_fence(currency:)
        )
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { currency:, rate_date: })
        RefreshStatus::Tracker.record_failure(refresh, error)
      ensure
        RefreshStatus::Tracker.advance(refresh)
      end
    end
  end

  private

  def importer
    @importer ||= HistoricalExchangeRate::Importer.default
  end

  def throttle
    @throttle ||= MarketData::YahooFinance::RequestThrottle.new
  end

  attr_reader :reporting_currency

  def performance_currencies
    trade_currencies = Instrument.where(id: Trade.where(user: User.owner).select(:instrument_id)).pluck(:currency)
    income_currencies = CorporateAction.effective_on_or_before(Date.current)
      .where(user: User.owner).includes(:instrument).map { |action| action.currency || action.instrument.currency }
    benchmark_currencies = MarketBenchmark.where(kind: MarketBenchmark::PERFORMANCE_KINDS).distinct.pluck(:currency)
    (trade_currencies | income_currencies | benchmark_currencies).excluding(reporting_currency)
  end

  def publication_fence(currency:)
    MarketData::PublicationFence.new(
      target: MarketData::Target.new(kind: :historical_exchange_rates,
        base_currency: currency, quote_currency: reporting_currency,
        provider: HistoricalExchangeRate::Providers::YahooFinance::IDENTIFIER)
    )
  end
end
