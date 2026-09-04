require "test_helper"

class PositionMaterializations::RebuildTest < ActiveSupport::TestCase
  test "rebuilds every instrument traded by the owner" do
    results = PositionMaterializations::Rebuild.call(user: users(:owner))

    assert_equal users(:owner).trades.distinct.count(:instrument_id), results.size
    assert results.all?(&:complete?)
  end

  test "rebuilds one requested instrument" do
    instrument = instruments(:voo_arcx)

    results = PositionMaterializations::Rebuild.call(user: users(:owner), instrument:)

    assert_equal [ instrument.id ], results.map(&:instrument_id)
    assert_predicate results.sole, :complete?
  end
end
