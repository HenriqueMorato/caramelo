class MarketDataHealthController < ApplicationController
  allow_unauthenticated_access

  def show
    @report = MarketData::HealthReport.for
    last_started_at = Rails.cache.read(CurrentMarketPriceRefreshesController::MANUAL_COOLDOWN_KEY)
    @market_price_refresh_available = last_started_at.nil? || Time.current - last_started_at >= CurrentMarketPriceRefreshesController::MANUAL_COOLDOWN
  end
end
