class MarketDataHealthController < ApplicationController
  def show
    @report = MarketData::HealthReport.for(owner: current_account)
    MarketPrice::ManualRefresh.call(user: current_account) if @report.current_prices_need_refresh?
    @market_price_refresh_available = MarketPrice::ManualRefresh.available?
    @status_filter = params[:status].presence_in(%w[all attention healthy]) || "all"
    @health = MarketData::HealthReportPresenter.new(
      report: @report, owner: current_account, status_filter: @status_filter
    )
    @entries = @health.entries
    @ignored_import_count = current_account.corporate_action_imports.where(status: :ignored).count
    @backup = Backup::Presenter.new(
      catalog: Backup::Catalog.call,
      state: Backup::State.current
    )
  end
end
