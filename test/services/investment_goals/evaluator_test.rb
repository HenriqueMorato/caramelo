require "test_helper"

class InvestmentGoals::EvaluatorTest < ActiveSupport::TestCase
  setup do
    @goal = users(:owner).investment_goals.create!(target_amount: "100")
  end

  test "marks an active reached target once" do
    progress = InvestmentGoals::Progress.for(
      goal: @goal, market_value: Money.from_amount(100, "BRL")
    )

    assert_changes -> { @goal.reload.status }, from: "active", to: "achieved" do
      InvestmentGoals::Evaluator.call(goal: @goal, progress:)
    end
    achieved_at = @goal.reload.achieved_at
    assert_not_nil achieved_at
    assert_nil @goal.celebration_seen_at
    assert_predicate @goal, :celebration_pending?

    InvestmentGoals::Evaluator.call(goal: @goal, progress:)
    assert_equal achieved_at, @goal.reload.achieved_at
  end

  test "leaves an unavailable or paused target unchanged" do
    unavailable = InvestmentGoals::Progress.for(goal: @goal, market_value: nil)
    InvestmentGoals::Evaluator.call(goal: @goal, progress: unavailable)
    assert_predicate @goal.reload, :active?

    @goal.pause!
    reached = InvestmentGoals::Progress.for(goal: @goal, market_value: Money.from_amount(100, "BRL"))
    InvestmentGoals::Evaluator.call(goal: @goal, progress: reached)
    assert_predicate @goal.reload, :paused?
  end

  test "rechecks the target after locking when progress has become stale" do
    progress = Data.define(:available?, :achieved?, :current_amount, :current_value).new(
      true, true, BigDecimal("50"), Money.from_amount(50, "BRL")
    )

    InvestmentGoals::Evaluator.call(goal: @goal, progress:)

    assert_predicate @goal.reload, :active?
  end
end
