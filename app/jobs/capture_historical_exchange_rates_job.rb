class CaptureHistoricalExchangeRatesJob < ApplicationJob
  queue_as :market_prices

  def perform(rate_date: nil)
    # Snapshot once per execution, rather than changing pairs midway through a batch.
    @reporting_currency = User.owner.reporting_currency
    rate_date ||= TradingCalendar.previous_business_day

    currencies = traded_currencies
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
          to: rate_date
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

  def traded_currencies
    Instrument.where(id: Trade.where(user: User.owner).select(:instrument_id))
      .where.not(currency: reporting_currency).distinct
      .pluck(:currency)
  end
end
