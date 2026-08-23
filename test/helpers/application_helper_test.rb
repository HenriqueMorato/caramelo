require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "formats quantities without unnecessary decimal places" do
    assert_equal "10", format_quantity(BigDecimal("10.00000000"))
    assert_equal "10.25", format_quantity(BigDecimal("10.25000000"))
  end

  test "formats unit prices with two to eight decimal places" do
    trade = trades(:owner_voo_buy)

    trade.unit_price = BigDecimal("32.4")
    assert_equal "$32.40", format_unit_price(trade)

    trade.unit_price = BigDecimal("0.12345678")
    assert_equal "$0.12345678", format_unit_price(trade)
  end
end
