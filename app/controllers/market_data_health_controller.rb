class MarketDataHealthController < ApplicationController
  allow_unauthenticated_access

  def show
    @report = MarketData::HealthReport.for
    MarketPrice::ManualRefresh.call if @report.current_prices_need_refresh?
    @market_price_refresh_available = MarketPrice::ManualRefresh.available?
    @status_filter = params[:status].presence_in(%w[all attention healthy]) || "all"
    @entries = filtered_entries
    @backup = Backup::Presenter.new(
      catalog: Backup::Catalog.call,
      state: Backup::State.current
    )
  end

  private

  def filtered_entries
    case @status_filter
    when "attention"
      @report.entries.reject(&:healthy?)
    when "healthy"
      @report.entries.select(&:healthy?)
    else
      @report.entries
    end
  end
end
