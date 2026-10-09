require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "masks money without including the formatted value" do
    @money_values_hidden = true

    rendered = display_money(Money.from_amount(1_234.56, "USD"))

    assert_includes rendered, ApplicationHelper::MONEY_MASK
    assert_includes rendered, "Monetary value hidden"
    refute_includes rendered, "$1,234.56"
  end

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

    trade.unit_price = BigDecimal("1234.56")
    assert_equal "$1,234.56", format_unit_price(trade)
  end

  test "formats unit price inputs without grouping delimiters" do
    assert_equal "1234.56789", format_unit_price_input(BigDecimal("1234.56789"))
  end

  test "formats a currency amount with its currency precision" do
    assert_equal "$1,234.57", format_currency_amount(BigDecimal("1234.56789"), "USD")
    assert_equal "R$10,00", format_currency_amount(BigDecimal("10"), "BRL")
    assert_equal "¥1,235", format_currency_amount(BigDecimal("1234.56"), "JPY")
  end

  test "falls back to not available only for nil values" do
    assert_equal "Not available", value_or_not_available(nil)
    assert_equal 0, value_or_not_available(0)
    assert_equal false, value_or_not_available(false)
    assert_equal true, value_or_not_available(true)
    assert_equal "Ready", value_or_not_available("Ready")
  end

  test "adds the shared select controller without replacing existing data attributes" do
    builder = CarameloFormBuilder.new("user", users(:owner), self, {})

    rendered = builder.custom_select(:reporting_currency, [ [ "Brazilian real", "BRL" ] ], {},
      class: "ui-field", data: { controller: "settings-form", action: "change->settings-form#sync" })

    assert_includes rendered, 'data-controller="settings-form caramelo-select"'
    assert_includes rendered, 'data-action="change-&gt;settings-form#sync"'
    assert_includes rendered, "data-caramelo-select-empty-label=\"No options available\""
  end

  test "uses the shared select controller for collection selects" do
    builder = CarameloFormBuilder.new("trade", trades(:owner_voo_buy), self, {})

    rendered = builder.custom_collection_select(:institution_id, [ institutions(:owner_xp) ], :id, :name)

    assert_includes rendered, 'data-controller="caramelo-select"'
    assert_includes rendered, institutions(:owner_xp).name
  end

  private

  def money_values_hidden?
    @money_values_hidden == true
  end
end
