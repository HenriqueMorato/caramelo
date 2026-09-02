class RefreshTradedMarketPricesJob < ApplicationJob
  queue_as :market_prices

  DEDUPLICATION_WINDOW = 5.minutes

  def self.enqueue_for
    return :coalesced unless Rails.cache.write(deduplication_key, true, expires_in: DEDUPLICATION_WINDOW, unless_exist: true)

    job = perform_later
    return job if job

    Rails.cache.delete(deduplication_key)
    nil
  rescue
    Rails.cache.delete(deduplication_key)
    raise
  end

  def perform
    traded_instruments.find_each do |instrument|
      unless market_price_service.supports?(instrument:)
        ActiveSupport::Notifications.instrument(
          "market_price.refresh",
          event: :skipped, provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier, instrument_id: instrument.id
        )
        next
      end

      lookup = market_price_service.read(instrument:)
      next unless lookup&.refresh_needed?

      RefreshCurrentMarketPriceJob.enqueue_for(instrument:)
    end
  ensure
    Rails.cache.delete(self.class.deduplication_key)
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

  def self.deduplication_key
    "localfolio:market_price:refresh_traded"
  end
end
