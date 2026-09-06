class CaptureDailyClosingPricesJob < ApplicationJob
  queue_as :market_prices

  def perform(trading_date: TradingCalendar.previous_business_day)
    instruments = traded_instruments
    RefreshStatus::Tracker.perform(scope: "daily_closing_prices", total_count: instruments.count) do |refresh|
      instruments.find_each do |instrument|
        next if DailyClosingPrice.exists?(instrument:, trading_date:, provider: DailyClosingPrice::Providers::YahooFinance::IDENTIFIER)

        request_throttle.wait!(instrument:)
        importer.call(instrument:, from: trading_date, to: trading_date, fence: publication_fence(instrument:))
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { instrument_id: instrument.id, trading_date: })
        RefreshStatus::Tracker.record_failure(refresh, error)
      ensure
        RefreshStatus::Tracker.advance(refresh)
      end
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

  def publication_fence(instrument:)
    MarketData::PublicationFence.new(
      target: MarketData::Target.new(kind: :daily_closing_prices, record_id: instrument.id,
        provider: DailyClosingPrice::Providers::YahooFinance::IDENTIFIER)
    )
  end
end
