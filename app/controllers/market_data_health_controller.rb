class MarketDataHealthController < ApplicationController
  allow_unauthenticated_access

  def show
    @report = MarketData::HealthReport.for
    MarketPrice::ManualRefresh.call if @report.current_prices_need_refresh?
    @market_price_refresh_available = MarketPrice::ManualRefresh.available?
  end
end
