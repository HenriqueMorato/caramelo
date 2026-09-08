class DashboardController < ApplicationController
  allow_unauthenticated_access

  def index
    @dashboard = Dashboard::Presenter.for
    @series = Performance::Series.for(from: @dashboard.performance.from, to: Date.current) if @dashboard.performance.available?
    @series_presenter = Performance::SeriesPresenter.new(@series) if @series
  end
end
