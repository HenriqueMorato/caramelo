class MarketDataHealthController < ApplicationController
  allow_unauthenticated_access

  def show
    @report = MarketData::HealthReport.for
    enqueue_refresh_if_needed
    last_started_at = Rails.cache.read(CurrentMarketPriceRefreshesController::MANUAL_COOLDOWN_KEY)
    @market_price_refresh_available = last_started_at.nil? ||
      Time.current - last_started_at >= CurrentMarketPriceRefreshesController::MANUAL_COOLDOWN
  end

  private

  def enqueue_refresh_if_needed
    return unless @report.current_prices_need_refresh? && manual_refresh_available?

    Rails.cache.write(CurrentMarketPriceRefreshesController::MANUAL_COOLDOWN_KEY, Time.current)
    RefreshTradedMarketPricesJob.enqueue_for
  end

  def manual_refresh_available?
    last_started_at = Rails.cache.read(CurrentMarketPriceRefreshesController::MANUAL_COOLDOWN_KEY)
    last_started_at.nil? || Time.current - last_started_at >= CurrentMarketPriceRefreshesController::MANUAL_COOLDOWN
  end
end
