class CaptureDailyClosingPricesJob < ApplicationJob
  queue_as :market_prices

  def perform(trading_date: MarketData::TradingCalendar.previous_business_day)
    traded_instruments.find_each do |instrument|
      next if DailyClosingPrice.exists?(instrument:, trading_date:, provider: DailyClosingPrice::Providers::YahooFinance::IDENTIFIER)

      request_throttle.wait!(instrument:)
      importer.call(instrument:, from: trading_date, to: trading_date)
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { instrument_id: instrument.id, trading_date: })
    end
  end

  private

  def importer
    @importer ||= DailyClosingPrice::Importer.default
  end

  def request_throttle
    @request_throttle ||= MarketData::YahooFinance::RequestThrottle.new
  end

  def traded_instruments
    Instrument.where(id: Trade.where(user: User.owner).select(:instrument_id))
  end
end
