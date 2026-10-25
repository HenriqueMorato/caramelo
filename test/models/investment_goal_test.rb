require "test_helper"

class InvestmentGoalTest < ActiveSupport::TestCase
  test "stores an exact target and exposes it as money" do
    goal = users(:owner).investment_goals.create!(
      target_amount: "1000000.12",
      target_on: Date.current
    )

    assert_equal BigDecimal("1000000.12"), goal.reload.target_amount
    assert_equal Money.from_amount(BigDecimal("1000000.12"), "BRL"), goal.target_value
    assert_predicate goal, :active?
    assert_predicate goal, :portfolio_value?
  end

  test "rejects a nonpositive target and past creation date" do
    goal = users(:owner).investment_goals.new(
      target_amount: "0", target_on: Date.current - 1
    )

    assert_not goal.valid?
    assert_includes goal.errors[:target_amount], "must be greater than 0"
    assert_includes goal.errors[:target_on], "must be today or a future date"
  end

  test "rejects malformed and over-precise targets and dates" do
    malformed = users(:owner).investment_goals.new(
      target_amount: "100USD", target_on: "2026-02-31"
    )

    assert_not malformed.valid?
    assert_includes malformed.errors[:target_amount], "is not a number"
    assert_includes malformed.errors[:target_on], "is invalid"

    over_precise = users(:owner).investment_goals.new(
      target_amount: "100.001"
    )

    assert_not over_precise.valid?
    assert_includes over_precise.errors[:target_amount], "cannot have more than 2 decimal places for this currency"
  end

  test "supports pausing, resuming, archiving, and resetting" do
    goal = users(:owner).investment_goals.create!(target_amount: "100")

    goal.resume!
    assert_predicate goal.reload, :active?
    goal.pause!
    assert_predicate goal.reload, :paused?
    goal.pause!
    assert_predicate goal.reload, :paused?
    goal.resume!
    assert_predicate goal.reload, :active?
    goal.target_amount = nil
    assert_nil goal.target_amount
    goal.target_amount = "100"

    goal.update!(status: :achieved, achieved_at: Time.current, celebration_seen_at: Time.current)
    assert_not_predicate goal, :celebration_pending?
    goal.reset!
    assert_predicate goal.reload, :active?
    assert_nil goal.achieved_at
    assert_nil goal.celebration_seen_at

    goal.archive!
    assert_predicate goal.reload, :archived?
    assert_not goal.archive!
    assert_not goal.reset!.nil?
    assert_predicate goal.reload, :active?
    assert_not goal.reset!
  end

  test "accepts a BigDecimal target and uses the account currency for precision" do
    goal = users(:owner).investment_goals.new(target_amount: BigDecimal("100.25"))
    assert_predicate goal, :valid?
    assert_equal BigDecimal("100.25"), goal.target_amount

    users(:owner).update!(reporting_currency: "USD")
    assert_equal Money.from_amount(BigDecimal("100.25"), "USD"), goal.target_value
  end

  test "reopens an achieved goal when its target changes" do
    goal = users(:owner).investment_goals.create!(
      target_amount: "100", status: :achieved,
      achieved_at: Time.current, celebration_seen_at: Time.current
    )

    goal.update!(target_amount: "200")

    assert_predicate goal.reload, :active?
    assert_nil goal.achieved_at
    assert_nil goal.celebration_seen_at
  end

  test "returns nil for an unsaved target amount" do
    assert_nil InvestmentGoal.new.target_amount
  end

  test "uses no currency when an unsaved goal has no user" do
    assert_nil InvestmentGoal.new.reporting_currency
  end

  test "skips precision validation when the account currency is unavailable" do
    goal = users(:owner).investment_goals.new(target_amount: "100.001")
    goal.define_singleton_method(:reporting_currency) { "ZZZ" }

    assert_predicate goal, :valid?
  end

  test "does not allow an archived goal to appear in the visible scope" do
    archived = users(:owner).investment_goals.create!(target_amount: "100")
    archived.archive!
    visible = users(:owner).investment_goals.create!(target_amount: "200")

    assert_equal [ visible ], users(:owner).investment_goals.visible.to_a
  end
end
