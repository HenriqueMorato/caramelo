require "test_helper"
require Rails.root.join("db/migrate/20260823120112_store_precise_trade_unit_prices")

class StorePreciseTradeUnitPricesTest < ActiveSupport::TestCase
  test "converts exactly representable prices to currency subunits" do
    migration = StorePreciseTradeUnitPrices.new

    assert_equal 123, migration.send(:exact_subunits, "1.23", "USD")
    assert_equal 3_245, migration.send(:exact_subunits, "32.45000000", "BRL")
  end

  test "rejects prices that would lose precision during rollback" do
    migration = StorePreciseTradeUnitPrices.new
    assert_nil migration.send(:exact_subunits, "1.23456789", "USD")
    assert_nil migration.send(:exact_subunits, "0.004", "USD")

    trades = [
      { "id" => 1, "unit_price" => "1.23456789", "currency" => "USD" },
      { "id" => 2, "unit_price" => "0.004", "currency" => "USD" }
    ]
    migration.define_singleton_method(:select_all) { |_query| trades }

    error = assert_raises(ActiveRecord::IrreversibleMigration) { migration.down }

    assert_match "Trade 1", error.message
    assert_match "cannot be represented in USD subunits", error.message
  end
end
