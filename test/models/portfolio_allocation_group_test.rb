require "test_helper"

class PortfolioAllocationGroupTest < ActiveSupport::TestCase
  setup do
    AssetType.ensure_defaults!
    @plan = PortfolioAllocationPlan.for(user: users(:owner))
    @first = instruments(:petr4_bvmf)
    @first.update!(asset_type: :etf)
    @second = Instrument.create!(
      ticker: "ALTG", exchange: "XNAS", name: "Allocation alternative", currency: "USD", asset_type: :etf
    )
  end

  test "accepts buy and hold members with the same asset type" do
    group = @plan.allocation_groups.build(name: "ETF alternatives", asset_type_key: "etf", target_percentage: 100)
    group.members.build(instrument: @first, purchase_policy: :hold)
    group.members.build(instrument: @second, purchase_policy: :buy)

    assert_predicate group, :valid?
    assert_predicate group.members.second, :buy?
    assert_predicate group.members.first, :hold?
  end

  test "requires two members and at least one buy member" do
    group = @plan.allocation_groups.build(name: "ETF alternatives", asset_type_key: "etf", target_percentage: 100)
    group.members.build(instrument: @first, purchase_policy: :hold)

    assert_not group.valid?
    assert_includes group.errors[:members], "must include at least two instruments"
    assert_includes group.errors[:members], "must include at least one Buy instrument"

    group.members.build(instrument: @second, purchase_policy: :hold)

    assert_not group.valid?
    assert_includes group.errors[:members], "must include at least one Buy instrument"
  end

  test "requires members to use the group's asset type" do
    bond = Instrument.create!(ticker: "ALTB", exchange: "BVMF", name: "Allocation bond", currency: "BRL", asset_type: :bond)
    group = @plan.allocation_groups.build(name: "ETF alternatives", asset_type_key: "etf", target_percentage: 100)
    member = group.members.build(instrument: bond, purchase_policy: :buy)

    assert_not member.valid?
    assert_includes member.errors[:instrument], "must use the group's asset type"
  end

  test "leaves the member asset type check to belongs_to when no instrument is present" do
    group = @plan.allocation_groups.build(name: "ETF alternatives", asset_type_key: "etf", target_percentage: 100)
    member = group.members.build(purchase_policy: :buy)

    assert_not member.valid?
    assert_includes member.errors[:instrument], "must exist"
    assert_empty member.errors[:instrument].grep("must use the group's asset type")
  end

  test "cascades members when a plan is deleted" do
    group = @plan.allocation_groups.create!(name: "ETF alternatives", asset_type_key: "etf", target_percentage: 100)
    group.members.create!(instrument: @first, purchase_policy: :hold)
    group.members.create!(instrument: @second, purchase_policy: :buy)

    assert_difference("PortfolioAllocationGroup.count", -1) do
      assert_difference("PortfolioAllocationGroupMember.count", -2) do
        @plan.destroy!
      end
    end
  end

  test "prevents deleting an instrument used by a group" do
    group = @plan.allocation_groups.create!(name: "ETF alternatives", asset_type_key: "etf", target_percentage: 100)
    group.members.create!(instrument: @first, purchase_policy: :hold)
    group.members.create!(instrument: @second, purchase_policy: :buy)

    assert_not @first.destroy
    assert_includes @first.errors[:base], "cannot be deleted while portfolio allocation targets or groups exist"
  end

  test "prevents changing an instrument asset type while it is allocated" do
    @plan.instrument_targets.create!(instrument: @first, asset_type_key: "etf", target_percentage: 100)

    @first.asset_type = "bond"

    assert_not @first.valid?
    assert_includes @first.errors[:asset_type], "cannot change while portfolio allocation targets or groups exist"
  end

  test "enforces case-insensitive group names in the database" do
    group = @plan.allocation_groups.create!(name: "ETF alternatives", asset_type_key: "etf", target_percentage: 100)
    now = Time.current

    assert_raises ActiveRecord::RecordNotUnique do
      PortfolioAllocationGroup.insert_all!([ {
        portfolio_allocation_plan_id: @plan.id,
        name: "ETF ALTERNATIVES",
        normalized_name: group.normalized_name,
        asset_type_key: "etf",
        target_percentage: 100,
        created_at: now,
        updated_at: now
      } ])
    end
  end
end
