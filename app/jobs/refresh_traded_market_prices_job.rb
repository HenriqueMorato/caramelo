class RefreshTradedMarketPricesJob < ApplicationJob
  queue_as :market_prices

  def perform
    traded_instruments.find_each do |instrument|
      unless market_price_service.supports?(instrument:)
        ActiveSupport::Notifications.instrument(
          "market_price.refresh",
          event: :skipped, provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier, instrument_id: instrument.id
        )
        next
      end

      RefreshCurrentMarketPriceJob.enqueue_for(instrument:)
    end
  end

  private

  def market_price_service
    MarketPrice::Service.default
  end

  def traded_instruments
    Instrument.where(
      id: Trade.where(user: User.owner).select(:instrument_id)
    )
  end
end
