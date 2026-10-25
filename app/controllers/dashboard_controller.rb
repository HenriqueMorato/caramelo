class DashboardController < ApplicationController
  def index
    @dashboard = Dashboard::Presenter.for(owner: current_account)
    prepare_investment_goals
    @series = Performance::Series.for(
      from: @dashboard.performance.from, to: Date.current, user: current_account
    ) if @dashboard.performance.available?
    @series_presenter = Performance::SeriesPresenter.new(@series) if @series
  end

  private

  def prepare_investment_goals
    @investment_goals = current_account.investment_goals.visible.to_a
    reporting_currency = current_account.reporting_currency
    market_value = @dashboard.complete_market_value_for(currency: reporting_currency)
    fresh_market_value = @dashboard.complete_fresh_market_value_for(currency: reporting_currency)
    market_value_amount = @dashboard.complete_market_value_amount_for(currency: reporting_currency)
    @investment_goal_progresses = @investment_goals.to_h do |goal|
      progress = InvestmentGoals::Progress.for(
        goal:, market_value:, market_value_amount:,
        fresh: fresh_market_value.present?
      )
      InvestmentGoals::Evaluator.call(goal:, progress:)
      [ goal.id, progress ]
    end
    @investment_goals.each(&:reload)
  end
end
