require "application_system_test_case"

class TradesTest < ApplicationSystemTestCase
  setup do
    page.current_window.resize_to(390, 844)
  end

  test "lists only the owner's trades" do
    visit transactions_path

    assert_text "Long-term allocation"
    assert_text "VOO"
    assert_text "Banco do Brasil"
    assert_no_text "Other owner trade"
  end

  test "shows an empty state without owner trades" do
    Trade.where(user: User.owner).delete_all

    visit transactions_path

    assert_text "No trades yet"
    assert_link "Add trade"
  end

  test "creates a trade from the global flow" do
    visit new_trade_path

    assert_select "Side *", selected: "Buy"
    select "PETR4 · BVMF — Petrobras PN", from: "Instrument"
    assert_field "Currency", with: "BRL", disabled: true
    select "Buy", from: "Side"
    fill_in "Trade date", with: "2026-08-20"
    fill_in "Quantity", with: "10.25"
    fill_in "Unit price", with: "32.45"
    fill_in "Fees", with: "4.90"
    select "XP Investimentos", from: "Institution (optional)"
    fill_in "Notes", with: "New position"
    click_on "Create Trade"

    assert_text "Trade was created."
    assert_text "PETR4 · BVMF"
    assert_text "New position"
    assert_text "XP Investimentos"
    assert_text "BRL"
  end

  test "quantity accepts fractions and increments by one full unit" do
    visit new_trade_path

    fill_in "Quantity", with: "0.25"
    find_field("Quantity").send_keys(:arrow_up)

    assert_field "Quantity", with: "1.25"
  end

  test "creates a trade from an instrument context" do
    instrument = instruments(:petr4_bvmf)

    visit instrument_path(instrument)
    click_on "Add trade"

    assert_text "PETR4 · BVMF"
    assert_no_select "Instrument"
    assert_field "Currency", with: "BRL", disabled: true
    select "Buy", from: "Side"
    fill_in "Trade date", with: "2026-08-21"
    fill_in "Quantity", with: "5"
    fill_in "Unit price", with: "33.10"
    fill_in "Fees", with: "2.50"
    click_on "Create Trade"

    assert_text "Trade was created."
    assert_text "PETR4 · BVMF"
  end

  test "edits a trade and keeps its inactive institution available" do
    trade = trades(:owner_voo_buy)

    visit transactions_path
    within "#trade_#{trade.id}" do
      click_on "Edit"
    end

    assert_select "Institution (optional)", selected: "Banco do Brasil"
    select "Sell", from: "Side"
    fill_in "Quantity", with: "1"
    fill_in "Unit price", with: "620"
    fill_in "Fees", with: "1.50"
    fill_in "Notes", with: "Reduced position"
    click_on "Update Trade"

    assert_text "Trade was updated."
    assert_text "SELL"
    assert_selector ".bg-red-100", text: "SELL"
    assert_text "1 × $620.00"
    assert_text "Reduced position"
    assert_text "Banco do Brasil"
  end

  test "shows validation errors and preserves values" do
    visit new_trade_path

    select "PETR4 · BVMF — Petrobras PN", from: "Instrument"
    select "Buy", from: "Side"
    fill_in "Trade date", with: "2026-08-20"
    fill_in "Quantity", with: "0"
    fill_in "Unit price", with: "0"
    fill_in "Fees", with: "0"
    fill_in "Notes", with: "Keep this note"
    click_on "Create Trade"

    assert_text "2 errors prevented this trade from being saved:"
    assert_text "Quantity must be greater than 0"
    assert_text "Unit price must be greater than 0"
    assert_field "Quantity", with: "0"
    assert_field "Unit price", with: "0.00"
    assert_field "Notes", with: "Keep this note"
  end

  test "deletes a trade with confirmation" do
    trade = trades(:owner_voo_buy)

    visit transactions_path

    within "#trade_#{trade.id}" do
      accept_confirm "Delete this trade?" do
        click_on "Delete"
      end
    end

    assert_current_path transactions_path
    assert_text "Trade was deleted."
    assert_no_text "Long-term allocation"
  end
end
