require "application_system_test_case"

class PositionsTest < ApplicationSystemTestCase
  setup do
    page.current_window.resize_to(390, 844)
  end

  test "shows an open position on a mobile viewport" do
    visit positions_path

    assert_text "Your little pack."
    assert_text "VOO"
    assert_text "ARCX"
    assert_text "Vanguard S&P 500 ETF"
    assert_text "2.5"
    assert_text "$611.60"
    assert_text "$1,529.00"
    assert_text "USD"

    click_on "VOO"

    assert_current_path instrument_path(instruments(:voo_arcx))
  end

  test "chooses nested grouping options and can clear grouping" do
    visit positions_path

    click_button "Type"
    assert_text "OTHER"
    assert_selector "button.grouping-option[data-grouping-value='asset_type'][aria-pressed='true'][data-grouping-slot='primary']"
    assert_selector "button.grouping-option[data-grouping-value='currency'][aria-pressed='false'][data-grouping-slot='']"

    click_button "Currency"
    assert_text "USD"
    assert_selector "button.grouping-option[data-grouping-value='currency'][aria-pressed='true'][data-grouping-slot='secondary']"

    click_button "Type"
    assert_selector "button.grouping-option[data-grouping-value='currency'][aria-pressed='true'][data-grouping-slot='primary']"
    assert_selector "button.grouping-option[data-grouping-value='asset_type'][aria-pressed='false'][data-grouping-slot='']"

    click_button "Clear"
    assert_selector "button.grouping-option[data-grouping-value='asset_type'][aria-pressed='false'][data-grouping-slot='']"
    assert_text "POSITION"
  end

  test "includes a closed position when requested" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy)
    create_trade(instrument:, side: :sell, traded_on: Date.new(2026, 1, 2))

    visit positions_path

    assert_no_text "PETR4"
    click_on "Include closed positions"

    assert_current_path positions_path(closed: 1)
    assert_text "PETR4"
    assert_text "BVMF"
    assert_text "Closed"
  end

  test "shows an unavailable B3 price without a refresh control" do
    instrument = instruments(:petr4_bvmf)
    create_trade(instrument:, side: :buy)

    visit positions_path

    within "#current_market_price_instrument_#{instrument.id}" do
      assert_text "Price unavailable"
      assert_no_button "Refresh"
    end
  end

  test "shows the empty state on a desktop viewport" do
    page.current_window.resize_to(1280, 900)
    Trade.where(user: User.owner).delete_all

    visit positions_path

    assert_text "No positions yet"
    assert_link "Add trade"
  end

  private

  def create_trade(instrument:, side:, traded_on: Date.new(2026, 1, 1))
    User.owner.trades.create!(
      instrument:,
      side:,
      traded_on:,
      quantity: 1,
      unit_price: 10,
      fees_cents: 0,
      currency: instrument.currency
    )
  end
end
