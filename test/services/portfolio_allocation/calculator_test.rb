require "test_helper"

class PortfolioAllocation::CalculatorTest < ActiveSupport::TestCase
  Snapshot = PortfolioAllocation::CurrentSnapshot

  setup do
    @owner = users(:owner)
    @stock = instruments(:petr4_bvmf)
    @stock.update!(asset_type: :stock)
    @bond = Instrument.create!(ticker: "ALBD", exchange: "BVMF", name: "Allocation bond", currency: "BRL", asset_type: :bond,
      quantity_step: "0.01")
    @plan = PortfolioAllocationPlan.for(user: @owner)
    @plan.asset_targets.create!(asset_type_key: "stock", target_percentage: 60)
    @plan.asset_targets.create!(asset_type_key: "bond", target_percentage: 40)
    @plan.instrument_targets.create!(instrument: @stock, asset_type_key: "stock", target_percentage: 100)
    @plan.instrument_targets.create!(instrument: @bond, asset_type_key: "bond", target_percentage: 100)
    @holdings = [ holding(@stock, "600", "10", "1"), holding(@bond, "400", "10", "0.01") ]
    @snapshot = Snapshot::Result.new(:available, @holdings, BigDecimal("1000"), [])
  end

  test "allocates new money toward the post-contribution target and keeps one percent reserve" do
    result = PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, contribution: "100", snapshot: @snapshot)

    assert_predicate result, :available?
    assert_equal BigDecimal("99"), result.investable_amount
    assert_equal BigDecimal("1"), result.reserve_amount
    assert_equal BigDecimal("1099"), result.projected_amount
    assert_equal [ :buy, :buy ], result.recommendations.map(&:action)
    assert_equal BigDecimal("5"), result.comparisons.first.quantity
    assert_equal BigDecimal("3.96"), result.comparisons.second.quantity
    assert_operator result.unallocated_amount, :>, BigDecimal("0")
  end

  test "reports sells and buys in full rebalance mode" do
    holdings = [ holding(@stock, "800", "10", "1"), holding(@bond, "200", "10", "0.01") ]
    snapshot = Snapshot::Result.new(:available, holdings, BigDecimal("1000"), [])

    result = PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, contribution: "100", mode: "full_rebalance", snapshot: snapshot)

    assert_equal [ :sell, :buy ], result.recommendations.map(&:action)
    assert_equal BigDecimal("14"), result.comparisons.first.quantity
    assert_equal BigDecimal("23.96"), result.comparisons.second.quantity
    assert_equal BigDecimal("0"), result.unallocated_amount
  end

  test "marks an overweight holding and a buy that is below one unit" do
    @plan.instrument_targets.delete_all
    @plan.asset_targets.find_by!(asset_type_key: "stock").update!(target_percentage: 80)
    @plan.asset_targets.find_by!(asset_type_key: "bond").update!(target_percentage: 20)
    stock = holding(@stock, "1000", "10", "1")
    tiny = holding(@bond, "99", "100", "1")
    snapshot = Snapshot::Result.new(:available, [ stock, tiny ], BigDecimal("1099"), [])

    result = PortfolioAllocation::Calculator.for(
      plan: @plan, owner: @owner, contribution: "1", snapshot:
    )

    assert_predicate result.comparisons.first, :overweight?
    assert_predicate result.comparisons.second, :below_minimum?
    assert_equal BigDecimal("0"), result.comparisons.second.quantity
  end

  test "falls back to buy-only mode for an unknown mode" do
    result = PortfolioAllocation::Calculator.for(
      plan: @plan, owner: @owner, contribution: "100", mode: "unknown", snapshot: @snapshot
    )

    assert_equal "buy_only", result.mode
  end

  test "splits an asset type evenly when no instrument targets are set" do
    @plan.instrument_targets.delete_all

    result = PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, snapshot: @snapshot)

    assert_equal BigDecimal("60"), result.comparisons.first.target_percentage
    assert_equal BigDecimal("40"), result.comparisons.second.target_percentage
  end

  test "rejects negative and malformed contributions" do
    assert_raises(ArgumentError) do
      PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, contribution: "-1", snapshot: @snapshot)
    end

    error = assert_raises(ArgumentError) do
      PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, contribution: "not-a-number", snapshot: @snapshot)
    end
    assert_equal "contribution is invalid", error.message
  end

  test "blocks recommendations when current data is incomplete" do
    issue = Snapshot::Issue.new(@bond, :stale)
    snapshot = Snapshot::Result.new(:incomplete, [], nil, [ issue ])

    result = PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, contribution: "100", snapshot: snapshot)

    assert_predicate result, :incomplete?
    assert_equal [ issue ], result.issues
    assert_empty result.comparisons
  end

  test "blocks a plan when one of its target instruments is no longer open" do
    closed = Instrument.create!(ticker: "CLOSED", exchange: "BVMF", name: "Closed target", currency: "BRL", asset_type: :stock)
    @plan.instrument_targets.create!(instrument: closed, asset_type_key: "stock", target_percentage: 10)

    result = PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, snapshot: @snapshot)

    assert_predicate result, :incomplete?
    assert_equal :closed, result.issues.first.kind
    assert_equal closed, result.issues.first.instrument
  end

  test "explains an empty or unconfigured plan" do
    empty = Snapshot::Result.new(:empty, [], BigDecimal("0"), [])
    result = PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, snapshot: empty)
    assert_predicate result, :empty?

    @plan.asset_targets.delete_all
    unconfigured = PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, snapshot: @snapshot)
    assert_predicate unconfigured, :unconfigured?
  end

  private

  def holding(instrument, amount, price, step)
    instrument.quantity_step = BigDecimal(step)
    Snapshot::Holding.new(instrument, Object.new, Object.new, Object.new,
      BigDecimal(amount), BigDecimal(amount) / BigDecimal(price), BigDecimal(price))
  end
end
