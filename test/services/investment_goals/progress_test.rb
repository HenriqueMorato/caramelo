require "test_helper"

class InvestmentGoals::ProgressTest < ActiveSupport::TestCase
  setup do
    @goal = users(:owner).investment_goals.create!(target_amount: "100")
  end

  test "calculates exact progress and clamps remaining value at zero" do
    progress = InvestmentGoals::Progress.for(
      goal: @goal, market_value: Money.from_amount(BigDecimal("125.125"), "BRL"),
      market_value_amount: BigDecimal("125.125")
    )

    assert_predicate progress, :available?
    assert_predicate progress, :achieved?
    assert_equal BigDecimal("125.125"), progress.current_amount
    assert_equal BigDecimal("1.25125"), progress.ratio
    assert_equal BigDecimal("0"), progress.remaining_amount
    assert_equal Money.from_amount(0, "BRL"), progress.remaining_value
  end

  test "returns an unavailable result without a complete market value" do
    [ nil, Money.from_amount(100, "USD") ].each do |market_value|
      progress = InvestmentGoals::Progress.for(goal: @goal, market_value:)

      assert_predicate progress, :unavailable?
      assert_nil progress.current_value
      assert_nil progress.ratio
      assert_equal @goal.target_value, progress.target_value
    end
  end

  test "does not mark a target as achieved below its amount" do
    progress = InvestmentGoals::Progress.for(
      goal: @goal, market_value: Money.from_amount(BigDecimal("99.99"), "BRL")
    )

    assert_not_predicate progress, :achieved?
    assert_equal BigDecimal("0.01"), progress.remaining_amount
    assert_equal BigDecimal("99.99"), progress.percentage
  end

  test "shows stale progress without marking the target reached" do
    progress = InvestmentGoals::Progress.for(
      goal: @goal, market_value: Money.from_amount(100, "BRL"), fresh: false
    )

    assert_predicate progress, :stale?
    assert_predicate progress, :available?
    assert_not_predicate progress, :fresh?
    assert_not_predicate progress, :achieved?
  end
end
