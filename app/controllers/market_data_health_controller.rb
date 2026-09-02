class MarketDataHealthController < ApplicationController
  allow_unauthenticated_access

  def show
    @report = MarketData::HealthReport.for
  end
end
