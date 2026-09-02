class CaptureHistoricalExchangeRatesJob < ApplicationJob
  queue_as :market_prices

  def perform(rate_date: nil)
    rate_date ||= MarketData::TradingCalendar.previous_business_day

    traded_currencies.each do |currency|
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
    end
  end

  private

  def importer
    @importer ||= HistoricalExchangeRate::Importer.default
  end

  def throttle
    @throttle ||= MarketData::YahooFinance::RequestThrottle.new
  end

  def reporting_currency
    Rails.configuration.x.local_folio.reporting_currency
  end

  def traded_currencies
    Instrument.where(id: Trade.where(user: User.owner).select(:instrument_id))
      .where.not(currency: reporting_currency).distinct
      .pluck(:currency)
  end
end
