require "test_helper"

class PortfolioAllocationPlanTest < ActiveSupport::TestCase
  test "keeps one plan per account and cascades its targets" do
    plan = PortfolioAllocationPlan.for(user: users(:owner))
    asset_target = plan.asset_targets.create!(asset_type_key: "stock", target_percentage: 100)
    instrument = instruments(:petr4_bvmf)
    instrument.update!(asset_type: :stock)
    plan.instrument_targets.create!(instrument:, asset_type_key: "stock", target_percentage: 100)

    assert_equal plan, PortfolioAllocationPlan.for(user: users(:owner))
    assert_raises ActiveRecord::RecordNotUnique do
      PortfolioAllocationPlan.insert_all!([ { user_id: users(:owner).id, created_at: Time.current, updated_at: Time.current } ])
    end

    assert_difference("PortfolioAllocationAssetTarget.count", -1) do
      assert_difference("PortfolioAllocationInstrumentTarget.count", -1) do
        plan.destroy!
      end
    end
    assert_not PortfolioAllocationAssetTarget.exists?(asset_target.id)
  end

  test "requires a positive quantity step" do
    instrument = instruments(:petr4_bvmf)

    instrument.quantity_step = 0

    assert_not instrument.valid?
    assert_includes instrument.errors[:quantity_step], "must be greater than 0"
  end

  test "requires an instrument target to use its registered asset type" do
    plan = PortfolioAllocationPlan.for(user: users(:owner))
    target = plan.instrument_targets.build(
      instrument: instruments(:petr4_bvmf), asset_type_key: "bond", target_percentage: 100
    )

    assert_not target.valid?
    assert_includes target.errors[:asset_type_key], "is not included in the list"
  end
end
