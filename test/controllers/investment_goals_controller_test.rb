require "test_helper"

class InvestmentGoalsControllerTest < ActionDispatch::IntegrationTest
  test "lists and creates a goal for the current account" do
    get investment_goals_url

    assert_response :success
    assert_select "h1", "Investment goals"
    assert_select "h2", "Your investment goals"
    assert_select "h3", "No investment goals yet"
    assert_select "#portfolio-allocation-heading", "Shape your portfolio mix"
    assert_select "a", "Open allocation planner"

    assert_difference("User.owner.investment_goals.count") do
      post investment_goals_url, params: {
        investment_goal: { target_amount: "1000000", target_on: Date.current + 1.year }
      }
    end

    goal = User.owner.investment_goals.order(:id).last
    assert_redirected_to investment_goals_url
    assert_equal BigDecimal("1000000"), goal.target_amount
    assert_equal "BRL", goal.reporting_currency
  end

  test "renders new and edit forms" do
    get new_investment_goal_url
    assert_response :success
    assert_select "h1", "Add investment goal"
    assert_select "select[name='investment_goal[reporting_currency]']", count: 0

    goal = User.owner.investment_goals.create!(target_amount: "100")
    get edit_investment_goal_url(goal)
    assert_response :success
    assert_select "h1", "Edit investment goal"
    assert_select "input[name='investment_goal[target_amount]'][value='100.0']"
  end

  test "does not expose target values while money visibility is hidden" do
    goal = User.owner.investment_goals.create!(target_amount: "100")

    patch money_visibility_url, params: { hidden: "true" }
    get edit_investment_goal_url(goal)

    assert_redirected_to root_url
    assert_equal "Show monetary values before editing transactions, income, or exporting data.", flash[:alert]
  end

  test "does not allow a request to assign another account" do
    post investment_goals_url, params: {
      investment_goal: {
        target_amount: "100", reporting_currency: "USD", user_id: users(:one).id,
        status: "achieved", kind: "other"
      }
    }

    assert_redirected_to investment_goals_url
    goal = User.owner.investment_goals.order(:id).last
    assert_equal "active", goal.status
    assert_equal "portfolio_value", goal.kind
    assert_equal User.owner, goal.user
  end

  test "renders validation errors and prevents a past target date" do
    post investment_goals_url, params: {
      investment_goal: { target_amount: "100", target_on: Date.current - 1 }
    }

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Target date must be today or a future date/
    assert_select "input[name='investment_goal[target_on]'][aria-invalid='true'][autofocus]"
    assert_select "input[name='investment_goal[target_on]'][aria-describedby*='investment-goal-date-error']"
  end

  test "updates and transitions a goal" do
    goal = User.owner.investment_goals.create!(target_amount: "100")

    patch investment_goal_url(goal), params: { investment_goal: { target_amount: "200", reporting_currency: "USD" } }
    assert_redirected_to investment_goals_url
    assert_equal BigDecimal("200"), goal.reload.target_amount
    assert_equal User.owner.reporting_currency, goal.reporting_currency

    post pause_investment_goal_url(goal)
    assert_predicate goal.reload, :paused?
    post resume_investment_goal_url(goal)
    assert_predicate goal.reload, :active?
    post archive_investment_goal_url(goal)
    assert_predicate goal.reload, :archived?
    post reset_investment_goal_url(goal)
    assert_predicate goal.reload, :active?
  end

  test "does not claim a transition that is no longer valid" do
    goal = User.owner.investment_goals.create!(target_amount: "100")

    post resume_investment_goal_url(goal)

    assert_redirected_to investment_goals_url
    assert_equal "Investment goal was already in that state.", flash[:notice]
    assert_predicate goal.reload, :active?
  end

  test "renders validation errors when an update is invalid" do
    goal = User.owner.investment_goals.create!(target_amount: "100")

    patch investment_goal_url(goal), params: { investment_goal: { target_amount: "0" } }

    assert_response :unprocessable_content
    assert_select "[role=alert]", /Target portfolio value must be greater than 0/
    assert_select "input[name='investment_goal[target_amount]'][aria-invalid='true'][autofocus]"
    assert_select "input[name='investment_goal[target_amount]'][aria-describedby*='investment-goal-target-error']"
  end

  test "uses the account reporting currency and ignores a submitted currency" do
    post investment_goals_url, params: {
      investment_goal: { target_amount: "100", reporting_currency: "USD" }
    }

    assert_redirected_to investment_goals_url
    assert_equal User.owner.reporting_currency, User.owner.investment_goals.order(:id).last.reporting_currency
  end

  test "acknowledges an achieved celebration only for the owner's goal" do
    goal = User.owner.investment_goals.create!(
      target_amount: "100", status: :achieved, achieved_at: Time.current
    )

    post acknowledge_celebration_investment_goal_url(goal), params: { achieved_at: goal.achieved_at.iso8601(6) }

    assert_response :no_content
    assert_not_nil goal.reload.celebration_seen_at
  end

  test "does not acknowledge an active goal" do
    goal = User.owner.investment_goals.create!(target_amount: "100")

    post acknowledge_celebration_investment_goal_url(goal)

    assert_response :no_content
    assert_nil goal.reload.celebration_seen_at
  end

  test "does not acknowledge an achieved goal without its achievement token" do
    goal = User.owner.investment_goals.create!(
      target_amount: "100", status: :achieved
    )

    post acknowledge_celebration_investment_goal_url(goal), params: { achieved_at: "stale" }

    assert_response :no_content
    assert_nil goal.reload.celebration_seen_at
  end

  test "does not acknowledge a celebration from an earlier achievement" do
    goal = User.owner.investment_goals.create!(
      target_amount: "100", status: :achieved, achieved_at: Time.current
    )
    earlier_achievement = goal.achieved_at.iso8601(6)

    goal.reset!
    post acknowledge_celebration_investment_goal_url(goal), params: { achieved_at: earlier_achievement }
    goal.update!(status: :achieved, achieved_at: Time.current)

    assert_nil goal.reload.celebration_seen_at
  end
end
