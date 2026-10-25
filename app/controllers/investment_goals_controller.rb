class InvestmentGoalsController < ApplicationController
  before_action :require_money_values_visible, only: %i[ new create edit update ]
  before_action :set_investment_goal, only: %i[ edit update pause resume archive reset acknowledge_celebration ]

  def index
    @investment_goals = current_account.investment_goals.manageable
  end

  def new
    @investment_goal = current_account.investment_goals.new(
      kind: :portfolio_value
    )
  end

  def create
    @investment_goal = current_account.investment_goals.new(investment_goal_params)
    @investment_goal.kind = :portfolio_value

    if @investment_goal.save
      redirect_to investment_goals_path, notice: t("investment_goals.notices.Created"), status: :see_other
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @investment_goal.update(investment_goal_params)
      redirect_to investment_goals_path, notice: t("investment_goals.notices.Updated"), status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  def pause
    redirect_after_transition(@investment_goal.pause!, :Paused)
  end

  def resume
    redirect_after_transition(@investment_goal.resume!, :Resumed)
  end

  def archive
    redirect_after_transition(@investment_goal.archive!, :Archived)
  end

  def reset
    redirect_after_transition(@investment_goal.reset!, :Reset)
  end

  def acknowledge_celebration
    @investment_goal.with_lock do
      if @investment_goal.achieved? && achieved_at_matches_request?
        @investment_goal.update!(celebration_seen_at: Time.current)
      end
    end
    head :no_content
  end

  private

  def set_investment_goal
    @investment_goal = current_account.investment_goals.find(params.expect(:id))
  end

  def investment_goal_params
    params.expect(investment_goal: %i[target_amount target_on])
  end

  def redirect_after_transition(changed, notice_key)
    key = changed ? notice_key : :NoChange
    redirect_to investment_goals_path, notice: t("investment_goals.notices.#{key}"), status: :see_other
  end

  def achieved_at_matches_request?
    requested = params[:achieved_at].to_s
    requested.present? && @investment_goal.achieved_at&.iso8601(6) == requested
  end
end
