require "test_helper"

class PositionGroupingTest < ActiveSupport::TestCase
  PositionStub = Struct.new(:instrument)

  test "preloads custom asset type labels for grouped positions" do
    custom = AssetType.create!(name: "Private credit")
    positions = [ PositionStub.new(nil), PositionStub.new(Instrument.new(asset_type: "stock")),
      PositionStub.new(Instrument.new(asset_type: custom.key)) ]
    grouping = Position::Grouping.new(primary: "asset_type", secondary: nil)

    assert_queries_count(1) { grouping.prepare_labels(positions) }
    assert_queries_count(0) do
      assert_equal "Stock", grouping.label("asset_type", "stock")
      assert_equal "Private credit", grouping.label("asset_type", custom.key)
    end
  end

  test "labels an asset type on demand when preparation was skipped" do
    grouping = Position::Grouping.new(primary: "asset_type", secondary: nil)

    assert_equal "ETF", grouping.label("asset_type", "etf")
  end

  test "does not query labels when asset type grouping is not selected" do
    grouping = Position::Grouping.new(primary: "currency", secondary: nil)
    position = PositionStub.new(instruments(:petr4_bvmf))

    assert_queries_count(0) { grouping.prepare_labels([ position ]) }
  end
end
