require "test_helper"

class PortfolioAllocation::PlanEditorTest < ActiveSupport::TestCase
  setup do
    AssetType.ensure_defaults!
    Trade.where(user: users(:owner)).delete_all
    @stock = instruments(:petr4_bvmf)
    @stock.update!(asset_type: :stock)
    @bond = Instrument.create!(ticker: "ALBD", exchange: "BVMF", name: "Allocation bond", currency: "BRL", asset_type: :bond)
    [ [ @stock, :buy ], [ @bond, :buy ] ].each do |instrument, side|
      users(:owner).trades.create!(instrument:, side:, traded_on: Date.new(2026, 1, 1), quantity: 1, unit_price: 10,
        fees_cents: 0, currency: instrument.currency)
    end
    @plan = PortfolioAllocationPlan.for(user: users(:owner))
  end

  test "saves exact asset and instrument targets for open holdings" do
    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "60", "bond" => "40" },
      instrument_targets: { @stock.id.to_s => "100", @bond.id.to_s => "100" }
    )

    assert_predicate result, :success?
    assert_equal({ "stock" => BigDecimal("60"), "bond" => BigDecimal("40") },
      @plan.asset_targets.reload.to_h { |target| [ target.asset_type_key, target.target_percentage ] })
    assert_equal({ @stock.id => BigDecimal("100"), @bond.id => BigDecimal("100") },
      @plan.instrument_targets.reload.to_h { |target| [ target.instrument_id, target.target_percentage ] })
  end

  test "completes blank asset targets and allows blank instrument targets" do
    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "60", "bond" => "" }, instrument_targets: {}
    )

    assert_predicate result, :success?
    assert_equal({ "stock" => BigDecimal("60"), "bond" => BigDecimal("40") },
      @plan.asset_targets.reload.to_h { |target| [ target.asset_type_key, target.target_percentage ] })
    assert_empty @plan.instrument_targets
  end

  test "rejects totals that do not reconcile" do
    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "60", "bond" => "30" },
      instrument_targets: { @stock.id.to_s => "100", @bond.id.to_s => "90" }
    )

    assert_not result.success?
    assert_includes result.errors, "Asset type targets must total 100%."
    assert_empty @plan.asset_targets
  end

  test "requires each asset type to have a complete instrument breakdown" do
    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "100" },
      instrument_targets: { @stock.id.to_s => "90" }
    )

    assert_not result.success?
    assert_includes result.errors, "Instrument targets for Stock must total 100%."
  end

  test "rejects unknown, malformed, and out-of-range target values" do
    unknown = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "not_registered" => "100" }, instrument_targets: {}
    )
    assert_includes unknown.errors, "Asset type not_registered is not registered."

    malformed = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "not-a-number" }, instrument_targets: { @stock.id.to_s => "not-a-number" }
    )
    assert malformed.errors.any? { |message| message.include?("is not a valid number") }

    out_of_range = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "-1" }, instrument_targets: { @stock.id.to_s => "101" }
    )
    assert_equal 2, out_of_range.errors.count { |message| message.include?("must be 0 or greater") }
  end

  test "requires nonzero values and targets for every selected type" do
    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "0", "bond" => "" },
      instrument_targets: { @stock.id.to_s => "0", @bond.id.to_s => "" }
    )

    assert_includes result.errors, "Choose at least one asset type target."
  end

  test "requires a type target for each instrument group and instruments for each type target" do
    missing_type = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "100" }, instrument_targets: { @bond.id.to_s => "100" }
    )
    assert_includes missing_type.errors, "Add an asset type target for Bond."

    missing_instruments = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "50", "crypto" => "50" }, instrument_targets: { @stock.id.to_s => "100" }
    )
    assert_includes missing_instruments.errors, "Choose instruments for Crypto."
  end

  test "reports a persistence validation failure" do
    failing_targets = @plan.asset_targets
    failing_targets.define_singleton_method(:create!) do |**|
      raise ActiveRecord::RecordInvalid, PortfolioAllocationAssetTarget.new
    end
    @plan.define_singleton_method(:asset_targets) { failing_targets }

    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "100" }, instrument_targets: { @stock.id.to_s => "100" }
    )

    assert_not result.success?
    assert_equal 1, result.errors.length
  end

  test "rejects instruments without an open position" do
    unheld = Instrument.create!(ticker: "UNHELD", exchange: "BVMF", name: "Unheld", currency: "BRL")
    invalid = Instrument.create!(ticker: "INVALID", exchange: "BVMF", name: "Invalid", currency: "BRL")
    users(:owner).trades.create!(instrument: invalid, side: :sell, traded_on: Date.new(2026, 1, 1), quantity: 1,
      unit_price: 10, fees_cents: 0, currency: invalid.currency)

    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "100" },
      instrument_targets: { unheld.id.to_s => "100" }
    )

    assert_not result.success?
    assert result.errors.any? { |message| message.include?("must have an open position") }
  end
end
