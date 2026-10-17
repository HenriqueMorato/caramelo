class DashboardController < ApplicationController
  def index
    @dashboard = Dashboard::Presenter.for(owner: current_account)
    @series = Performance::Series.for(
      from: @dashboard.performance.from, to: Date.current, user: current_account
    ) if @dashboard.performance.available?
    @series_presenter = Performance::SeriesPresenter.new(@series) if @series
  end
end
