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
    assert_equal BigDecimal("0"), result.comparisons.first.overshoot_amount
    assert_operator result.unallocated_amount, :>, BigDecimal("0")
  end

  test "limits purchases to the requested number of instruments and flags an overshoot" do
    result = PortfolioAllocation::Calculator.for(
      plan: @plan, owner: @owner, contribution: "100", instrument_count: "1", snapshot: @snapshot
    )

    assert_equal [ @stock ], result.recommendations.map(&:instrument)
    assert_equal BigDecimal("9"), result.recommendations.first.quantity
    assert_predicate result.recommendations.first, :over_target_after_purchase?
    assert_equal BigDecimal("30.6"), result.recommendations.first.overshoot_amount
    assert_equal BigDecimal("9"), result.unallocated_amount
  end

  test "uses a second instrument to spend a fractional remainder when possible" do
    result = PortfolioAllocation::Calculator.for(
      plan: @plan, owner: @owner, contribution: "100", instrument_count: "2", snapshot: @snapshot
    )

    assert_equal [ :buy, :buy ], result.recommendations.map(&:action)
    assert_equal BigDecimal("0"), result.unallocated_amount
    assert_equal BigDecimal("4.9"), result.comparisons.second.quantity
    assert_equal BigDecimal("9.4"), result.comparisons.second.overshoot_amount
    assert_predicate result, :over_target?
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

  test "rejects an invalid instrument count" do
    error = assert_raises(ArgumentError) do
      PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, instrument_count: "0", snapshot: @snapshot)
    end
    assert_equal "instrument_count is invalid", error.message

    error = assert_raises(ArgumentError) do
      PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, instrument_count: "many", snapshot: @snapshot)
    end
    assert_equal "instrument_count is invalid", error.message
  end

  test "divides an asset remainder among holdings without explicit instrument targets" do
    second_stock = Instrument.create!(ticker: "STK2", exchange: "BVMF", name: "Second stock", currency: "BRL", asset_type: :stock)
    @plan.instrument_targets.delete_all
    @plan.instrument_targets.create!(instrument: @stock, asset_type_key: "stock", target_percentage: 60)
    @plan.instrument_targets.create!(instrument: @bond, asset_type_key: "bond", target_percentage: 100)
    holdings = [ holding(@stock, "300", "10", "1"), holding(second_stock, "100", "10", "1"), holding(@bond, "600", "10", "1") ]
    snapshot = Snapshot::Result.new(:available, holdings, BigDecimal("1000"), [])

    result = PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, snapshot: snapshot)

    omitted = result.comparisons.find { |comparison| comparison.instrument == second_stock }
    assert_equal BigDecimal("40"), omitted.instrument_percentage
  end

  test "assigns zero to an omitted holding when explicit targets use the full share" do
    second_stock = Instrument.create!(ticker: "STK3", exchange: "BVMF", name: "Third stock", currency: "BRL", asset_type: :stock)
    @plan.instrument_targets.delete_all
    @plan.instrument_targets.create!(instrument: @stock, asset_type_key: "stock", target_percentage: 100)
    @plan.instrument_targets.create!(instrument: @bond, asset_type_key: "bond", target_percentage: 100)
    holdings = [ holding(@stock, "300", "10", "1"), holding(second_stock, "100", "10", "1"), holding(@bond, "600", "10", "1") ]
    snapshot = Snapshot::Result.new(:available, holdings, BigDecimal("1000"), [])

    result = PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, snapshot: snapshot)

    omitted = result.comparisons.find { |comparison| comparison.instrument == second_stock }
    assert_equal BigDecimal("0"), omitted.instrument_percentage
  end

  test "keeps hold members in place and directs a group's target to buy members" do
    second_stock = Instrument.create!(ticker: "STK4", exchange: "BVMF", name: "Grouped stock", currency: "BRL", asset_type: :stock)
    @plan.instrument_targets.delete_all
    @plan.instrument_targets.create!(instrument: @bond, asset_type_key: "bond", target_percentage: 100)
    group = @plan.allocation_groups.create!(name: "Stock alternatives", asset_type_key: "stock", target_percentage: 100)
    group.members.create!(instrument: @stock, purchase_policy: :hold)
    group.members.create!(instrument: second_stock, purchase_policy: :buy)
    snapshot = Snapshot::Result.new(
      :available,
      [ holding(@stock, "300", "10", "1"), holding(second_stock, "100", "10", "1"), holding(@bond, "600", "10", "1") ],
      BigDecimal("1000"), []
    )

    result = PortfolioAllocation::Calculator.for(
      plan: @plan, owner: @owner, contribution: "100", mode: "full_rebalance", snapshot:
    )
    hold = result.comparisons.find { |comparison| comparison.instrument == @stock }
    buy = result.comparisons.find { |comparison| comparison.instrument == second_stock }

    assert_predicate hold, :grouped?
    assert_predicate hold, :hold?
    assert_equal :none, hold.action
    assert_equal BigDecimal("300"), hold.target_amount
    assert_predicate buy, :grouped?
    assert_equal BigDecimal("359.4"), buy.target_amount
    assert_equal :buy, buy.action
  end

  test "assigns the remaining asset share to ungrouped instruments" do
    second_stock = Instrument.create!(ticker: "STK5", exchange: "BVMF", name: "Grouped stock", currency: "BRL", asset_type: :stock)
    third_stock = Instrument.create!(ticker: "STK6", exchange: "BVMF", name: "Ungrouped stock", currency: "BRL", asset_type: :stock)
    @plan.instrument_targets.delete_all
    @plan.instrument_targets.create!(instrument: @bond, asset_type_key: "bond", target_percentage: 100)
    group = @plan.allocation_groups.create!(name: "Stock alternatives", asset_type_key: "stock", target_percentage: 60)
    group.members.create!(instrument: @stock, purchase_policy: :hold)
    group.members.create!(instrument: second_stock, purchase_policy: :buy)
    snapshot = Snapshot::Result.new(
      :available,
      [ holding(@stock, "300", "10", "1"), holding(second_stock, "100", "10", "1"), holding(third_stock, "100", "10", "1"), holding(@bond, "500", "10", "1") ],
      BigDecimal("1000"), []
    )

    result = PortfolioAllocation::Calculator.for(plan: @plan, owner: @owner, snapshot:)
    ungrouped = result.comparisons.find { |comparison| comparison.instrument == third_stock }

    assert_equal BigDecimal("40"), ungrouped.instrument_percentage
    assert_equal BigDecimal("24"), ungrouped.target_percentage
  end

  test "returns no target amount when a grouped member is neither buy nor hold" do
    group = @plan.allocation_groups.create!(name: "Stock alternatives", asset_type_key: "stock", target_percentage: 100)
    group.members.create!(instrument: @stock, purchase_policy: :hold)
    member = Struct.new(:instrument_id) do
      def hold? = false
      def buy? = false
    end.new(@stock.id)
    calculator = PortfolioAllocation::Calculator.new(
      plan: @plan, owner: @owner, contribution: "0", mode: "buy_only", instrument_count: nil,
      reporting_currency: "BRL", market_price_service: MarketPrice::Service.default,
      exchange_rate_service: ExchangeRate::Service.default, snapshot: @snapshot
    )

    amount = calculator.send(:grouped_target_amount, group, member, { @stock.id => @holdings.first })

    assert_equal BigDecimal("0"), amount
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
