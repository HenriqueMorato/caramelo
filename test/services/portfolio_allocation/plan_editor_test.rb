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

  test "splits a remainder across multiple blank asset targets" do
    etf = Instrument.create!(ticker: "ALBE", exchange: "BVMF", name: "Allocation ETF", currency: "BRL", asset_type: :etf)
    users(:owner).trades.create!(instrument: etf, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 1,
      unit_price: 10, fees_cents: 0, currency: etf.currency)

    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "50", "bond" => "", "etf" => "" }, instrument_targets: {}
    )

    assert_predicate result, :success?
    assert_equal({ "stock" => BigDecimal("50"), "bond" => BigDecimal("25"), "etf" => BigDecimal("25") },
      @plan.asset_targets.reload.to_h { |target| [ target.asset_type_key, target.target_percentage ] })
  end

  test "accepts a partial instrument breakdown while other holdings remain blank" do
    second_stock = Instrument.create!(ticker: "ALBS", exchange: "BVMF", name: "Second allocation stock", currency: "BRL", asset_type: :stock)
    users(:owner).trades.create!(instrument: second_stock, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 1,
      unit_price: 10, fees_cents: 0, currency: second_stock.currency)

    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "100" }, instrument_targets: { @stock.id.to_s => "60" }
    )

    assert_predicate result, :success?
  end

  test "ignores a blank alias for an already parsed asset target" do
    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "60", " STOCK " => "" }, instrument_targets: {}
    )

    assert_not result.success?
    assert_includes result.errors, "Asset type targets must total 100%."
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

  test "requires a type target for each instrument group and allows future asset types" do
    missing_type = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "100" }, instrument_targets: { @bond.id.to_s => "100" }
    )
    assert_includes missing_type.errors, "Add an asset type target for Bond."

    future_asset_type = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "50", "crypto" => "50" }, instrument_targets: { @stock.id.to_s => "100" }
    )
    assert_predicate future_asset_type, :success?
    assert_equal({ "stock" => BigDecimal("50"), "crypto" => BigDecimal("50") },
      @plan.asset_targets.reload.to_h { |target| [ target.asset_type_key, target.target_percentage ] })
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

  test "saves an allocation group and removes grouped instruments from direct targets" do
    second_stock = add_second_stock
    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "60", "bond" => "40" },
      instrument_targets: { @bond.id.to_s => "100" },
      groups: group_attributes(
        name: "ETF alternatives", asset_type_key: "stock", target_percentage: "100",
        members: {
          @stock.id.to_s => { selected: "1", purchase_policy: "hold" },
          second_stock.id.to_s => { selected: "1", purchase_policy: "buy" }
        }
      )
    )

    assert_predicate result, :success?
    group = @plan.reload.allocation_groups.includes(:members).sole
    assert_equal "ETF alternatives", group.name
    assert_equal BigDecimal("100"), group.target_percentage
    assert_equal({ @stock.id => "hold", second_stock.id => "buy" },
      group.members.to_h { |member| [ member.instrument_id, member.purchase_policy ] })
    assert_equal [ @bond.id ], @plan.instrument_targets.pluck(:instrument_id)
  end

  test "allows a group to share the remainder with ungrouped instruments" do
    second_stock = add_second_stock
    third_stock = Instrument.create!(ticker: "ALB3", exchange: "BVMF", name: "Third allocation stock", currency: "BRL", asset_type: :stock)
    users(:owner).trades.create!(instrument: third_stock, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 1,
      unit_price: 10, fees_cents: 0, currency: third_stock.currency)

    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "60", "bond" => "40" },
      instrument_targets: { @bond.id.to_s => "100" },
      groups: group_attributes(
        name: "ETF alternatives", asset_type_key: "stock", target_percentage: "60",
        members: {
          @stock.id.to_s => { selected: "1", purchase_policy: "hold" },
          second_stock.id.to_s => { selected: "1", purchase_policy: "buy" }
        }
      )
    )

    assert_predicate result, :success?
  end

  test "rejects groups with too few members or without a buy member" do
    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: group_attributes(
        name: "ETF alternatives", asset_type_key: "stock", target_percentage: "100",
        members: { @stock.id.to_s => { selected: "1", purchase_policy: "hold" } }
      )
    )

    assert_not result.success?
    assert_includes result.errors, "Group ETF alternatives must include at least two instruments."

    second_stock = add_second_stock
    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: group_attributes(
        name: "ETF alternatives", asset_type_key: "stock", target_percentage: "100",
        members: {
          @stock.id.to_s => { selected: "1", purchase_policy: "hold" },
          second_stock.id.to_s => { selected: "1", purchase_policy: "hold" }
        }
      )
    )

    assert_not result.success?
    assert_includes result.errors, "Group ETF alternatives must have at least one instrument marked Buy."
  end

  test "rejects group overlap, duplicate names, and invalid member policies" do
    second_stock = add_second_stock
    overlapping = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "100" }, instrument_targets: { @stock.id.to_s => "100" },
      groups: group_attributes(
        name: "ETF alternatives", asset_type_key: "stock", target_percentage: "100",
        members: {
          @stock.id.to_s => { selected: "1", purchase_policy: "hold" },
          second_stock.id.to_s => { selected: "1", purchase_policy: "buy" }
        }
      )
    )
    assert_includes overlapping.errors, "Instrument PETR4 cannot have an individual target and a group target."

    invalid_policy = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: group_attributes(
        name: "ETF alternatives", asset_type_key: "stock", target_percentage: "100",
        members: {
          @stock.id.to_s => { selected: "1", purchase_policy: "something" },
          second_stock.id.to_s => { selected: "1", purchase_policy: "buy" }
        }
      )
    )
    assert invalid_policy.errors.any? { |message| message.include?("invalid group purchase policy") }
  end

  test "ignores an empty new-group card" do
    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner),
      asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: {
        "new_stock" => {
          asset_type_key: "stock", name: "", target_percentage: "",
          members: { @stock.id.to_s => { selected: "0", purchase_policy: "buy" } }
        }
      }
    )

    assert_predicate result, :success?
    assert_empty @plan.reload.allocation_groups
  end

  test "handles missing parameter maps and malformed group cards" do
    missing = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: Object.new, instrument_targets: Object.new, groups: Object.new
    )
    assert_not missing.success?
    assert_includes missing.errors, "Choose at least one asset type target."

    nil_group = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: { "nil_group" => Object.new }
    )
    assert_predicate nil_group, :success?

    malformed_member = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: {
        "malformed" => {
          name: "Malformed", asset_type_key: "stock", target_percentage: "100",
          members: { @stock.id.to_s => Object.new }
        }
      }
    )
    assert_includes malformed_member.errors, "Group Malformed must include at least two instruments."
  end

  test "skips a group marked for removal" do
    result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: {
        "removed" => {
          remove: "1", name: "Old alternatives", asset_type_key: "stock", target_percentage: "100",
          members: { @stock.id.to_s => { selected: "1", purchase_policy: "buy" } }
        }
      }
    )

    assert_predicate result, :success?
    assert_empty @plan.reload.allocation_groups
  end

  test "removes a persisted group marked for removal" do
    second_stock = add_second_stock
    group = group_attributes(
      name: "ETF alternatives", asset_type_key: "stock", target_percentage: "100",
      members: {
        @stock.id.to_s => { selected: "1", purchase_policy: "hold" },
        second_stock.id.to_s => { selected: "1", purchase_policy: "buy" }
      }
    ).fetch("group")
    created = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "60", "bond" => "40" },
      instrument_targets: { @bond.id.to_s => "100" }, groups: { "new_stock" => group }
    )
    assert_predicate created, :success?
    persisted_group = @plan.reload.allocation_groups.sole

    removal = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "60", "bond" => "40" },
      instrument_targets: { @bond.id.to_s => "100" },
      groups: { persisted_group.id.to_s => group.merge(remove: "1") }
    )

    assert_predicate removal, :success?
    assert_empty @plan.reload.allocation_groups
    assert_not PortfolioAllocationGroupMember.exists?(portfolio_allocation_group_id: persisted_group.id)
  end

  test "replaces an existing group without leaving orphaned members" do
    second_stock = add_second_stock
    attributes = group_attributes(
      name: "ETF alternatives", asset_type_key: "stock", target_percentage: "100",
      members: {
        @stock.id.to_s => { selected: "1", purchase_policy: "hold" },
        second_stock.id.to_s => { selected: "1", purchase_policy: "buy" }
      }
    )
    first = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "60", "bond" => "40" },
      instrument_targets: { @bond.id.to_s => "100" }, groups: attributes
    )
    assert_predicate first, :success?
    group_id = @plan.reload.allocation_groups.sole.id

    replacement = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "60", "bond" => "40" },
      instrument_targets: { @bond.id.to_s => "100" }, groups: {}
    )

    assert_predicate replacement, :success?
    assert_empty @plan.reload.allocation_groups
    assert_not PortfolioAllocationGroupMember.exists?(portfolio_allocation_group_id: group_id)
  end

  test "rejects unheld and cross-asset group members" do
    unheld = Instrument.create!(ticker: "UNGRP", exchange: "BVMF", name: "Unheld group instrument", currency: "BRL", asset_type: :stock)
    unheld_result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: group_attributes(
        name: "ETF alternatives", asset_type_key: "stock", target_percentage: "100",
        members: {
          @stock.id.to_s => { selected: "1", purchase_policy: "hold" },
          unheld.id.to_s => { selected: "1", purchase_policy: "buy" }
        }
      )
    )
    assert unheld_result.errors.any? { |message| message.include?("must have an open position before it can be grouped") }

    cross_asset_result = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: group_attributes(
        name: "ETF alternatives", asset_type_key: "stock", target_percentage: "100",
        members: {
          @stock.id.to_s => { selected: "1", purchase_policy: "hold" },
          @bond.id.to_s => { selected: "1", purchase_policy: "buy" }
        }
      )
    )
    assert cross_asset_result.errors.any? { |message| message.include?("must use the Stock asset type") }
  end

  test "rejects duplicate group membership and invalid group headers" do
    second_stock = add_second_stock
    third_stock = Instrument.create!(ticker: "ALB7", exchange: "BVMF", name: "Third grouped stock", currency: "BRL", asset_type: :stock)
    users(:owner).trades.create!(instrument: third_stock, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 1,
      unit_price: 10, fees_cents: 0, currency: third_stock.currency)

    duplicate = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: {
        first: group_attributes(
          name: "First", asset_type_key: "stock", target_percentage: "50",
          members: {
            @stock.id.to_s => { selected: "1", purchase_policy: "hold" },
            second_stock.id.to_s => { selected: "1", purchase_policy: "buy" }
          }
        ).fetch("group"),
        second: group_attributes(
          name: "First", asset_type_key: "stock", target_percentage: "50",
          members: {
            @stock.id.to_s => { selected: "1", purchase_policy: "hold" },
            third_stock.id.to_s => { selected: "1", purchase_policy: "buy" }
          }
        ).fetch("group")
      }
    )
    assert_includes duplicate.errors, "An instrument can belong to only one allocation group."
    assert_includes duplicate.errors, "Allocation group names must be unique."

    missing_name = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: { invalid: { name: "", asset_type_key: "stock", target_percentage: "100" } }
    )
    assert_includes missing_name.errors, "Allocation groups need a name."

    missing_target = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: { invalid: { name: "Missing target", asset_type_key: "stock", target_percentage: "" } }
    )
    assert_includes missing_target.errors, "The group Missing target percentage is not a valid number."

    unknown_type = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: { invalid: { name: "Unknown", asset_type_key: "not_registered", target_percentage: "100" } }
    )
    assert_includes unknown_type.errors, "Asset type not_registered is not registered."

    zero_target = PortfolioAllocation::PlanEditor.call(
      plan: @plan, owner: users(:owner), asset_targets: { "stock" => "100" }, instrument_targets: {},
      groups: { invalid: { name: "Zero", asset_type_key: "stock", target_percentage: "0" } }
    )
    assert_includes zero_target.errors, "Group Zero must have a positive target percentage."
  end

  private

  def add_second_stock
    @second_stock ||= Instrument.create!(ticker: "ALB2", exchange: "BVMF", name: "Second allocation stock", currency: "BRL", asset_type: :stock).tap do |instrument|
      users(:owner).trades.create!(instrument:, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 1,
        unit_price: 10, fees_cents: 0, currency: instrument.currency)
    end
  end

  def group_attributes(name:, asset_type_key:, target_percentage:, members:)
    {
      "group" => {
        name: name, asset_type_key: asset_type_key, target_percentage: target_percentage,
        members:
      }
    }
  end
end
