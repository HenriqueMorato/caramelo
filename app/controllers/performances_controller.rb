class PerformancesController < ApplicationController
  allow_unauthenticated_access

  PERIODS = {
    "week" => 1.week,
    "month" => 1.month,
    "year" => 1.year,
    "all" => nil
  }.freeze

  def show
    @selected_period = params[:period].presence_in(PERIODS.keys) || "month"
    @performance = Performance::Period.for(from: period_start, to: Date.current)
  end

  private

  def period_start
    return User.owner.trades.minimum(:traded_on) || Date.current if @selected_period == "all"

    Date.current - PERIODS.fetch(@selected_period)
  end
end
