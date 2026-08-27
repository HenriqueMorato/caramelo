class RefreshTradedMarketPricesJob < ApplicationJob
  queue_as :market_prices

  def perform
    traded_instruments.find_each do |instrument|
      next unless market_price_service.supports?(instrument:)

      RefreshCurrentMarketPriceJob.perform_later(instrument)
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
