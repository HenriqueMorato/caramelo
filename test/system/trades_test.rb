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

  test "filters activity immediately by transaction type" do
    income = CorporateAction.create!(
      user: User.owner, instrument: instruments(:petr4_bvmf), kind: :dividend,
      status: :confirmed, paid_on: Date.new(2026, 8, 25), gross_amount_cents: 1_234,
      withholding_tax_cents: 185, net_amount_cents: 1_049, currency: "BRL", source: "manual"
    )
    visit transactions_path

    click_on "Income"

    assert_current_path transactions_path(activity: "income")
    assert_selector "#corporate_action_#{income.id}"
    assert_no_text "Long-term allocation"

    click_on "All"

    assert_current_path transactions_path
    assert_text "Long-term allocation"
    assert_selector "#corporate_action_#{income.id}"
  end

  test "shows the review banner only when imported events are pending" do
    CorporateActionImport.create!(
      user: User.owner, instrument: instruments(:petr4_bvmf), source: "yahoo_finance",
      source_reference: "system-banner-review", status: :pending, kind: :split,
      event_on: Date.current, ratio_numerator: 2, ratio_denominator: 1, currency: "BRL",
      normalized_data: {}, raw_payload: {}, warnings: []
    )

    visit transactions_path

    within "[data-testid='corporate-action-import-review-banner']" do
      assert_text "1 imported market event is waiting for your review."
      click_on "Review imports"
    end
    assert_current_path corporate_action_imports_path
  end

  test "shows an empty state without owner activity" do
    Trade.where(user: User.owner).delete_all
    CorporateAction.where(user: User.owner).delete_all

    visit transactions_path

    assert_text "No activity yet"
    find("summary", text: "Add").click
    assert_link "Trade"
    assert_link "Income"
  end

  test "closes the add menu after an outside click" do
    visit transactions_path

    menu = find("details[data-testid='add-transaction-menu']")
    menu.find("summary").click
    assert_selector "details[data-testid='add-transaction-menu'][open]"

    find("h1").click

    assert_no_selector "details[data-testid='add-transaction-menu'][open]"
  end

  test "shows populated and empty transaction states on desktop" do
    page.current_window.resize_to(1280, 900)
    trade = trades(:owner_voo_buy)

    visit transactions_path

    within "#trade_#{trade.id}" do
      assert_text "VOO"
      assert_text "Banco do Brasil"
      assert_link "Edit"
      assert_button "Delete"
    end

    Trade.where(user: User.owner).delete_all
    CorporateAction.where(user: User.owner).delete_all
    visit transactions_path

    assert_text "No activity yet"
    find("summary", text: "Add").click
    assert_link "Trade"
    assert_link "Income"
  end

  test "creates a trade from the global flow" do
    visit new_trade_path

    assert_select "Side *", selected: "Buy"
    assert_select "Institution (optional)", selected: "No institution"
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

    assert_current_path transactions_path, wait: 10
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

  test "selecting an instrument remembers only that instrument's last institution" do
    remembered_trade = trades(:owner_voo_buy).dup
    remembered_trade.assign_attributes(instrument: instruments(:petr4_bvmf), institution: institutions(:owner_xp), currency: "BRL")
    remembered_trade.save!

    visit new_trade_path

    assert_select "Institution (optional)", selected: "No institution"
    select "PETR4 · BVMF — Petrobras PN", from: "Instrument"
    assert_select "Institution (optional)", selected: "XP Investimentos"
    select "VOO · ARCX — Vanguard S&P 500 ETF", from: "Instrument"
    assert_select "Institution (optional)", selected: "No institution"
  end

  test "creates a trade from an instrument context" do
    instrument = instruments(:petr4_bvmf)
    remembered_trade = trades(:owner_voo_buy).dup
    remembered_trade.assign_attributes(instrument: instrument, institution: institutions(:owner_xp), currency: "BRL")
    remembered_trade.save!

    visit instrument_path(instrument)
    within("[aria-labelledby='activity-history-heading']") do
      find("summary", text: "Add").click
      within("details[data-testid='add-instrument-transaction-menu']") do
        click_on "Trade"
      end
    end

    assert_text "PETR4 · BVMF"
    assert_no_select "Instrument"
    assert_field "trade[instrument_id]", type: "hidden", with: instrument.id, visible: false
    assert_field "Currency", with: "BRL", disabled: true
    assert_select "Institution (optional)", selected: "XP Investimentos"
    select "Buy", from: "Side"
    fill_in "Trade date", with: "2026-08-21"
    fill_in "Quantity", with: "5"
    fill_in "Unit price", with: "33.10"
    fill_in "Fees", with: "2.50"
    click_on "Create Trade"

    assert_current_path transactions_path, wait: 10
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

    assert_current_path transactions_path
    assert_text "Trade was updated."
    within "#trade_#{trade.id}" do
      assert_selector ".ui-badge-sell", text: "SELL"
      assert_selector "td", exact_text: "1"
      assert_selector "td", exact_text: "$620.00"
      assert_text "Reduced position"
      assert_text "Banco do Brasil"
    end
  end

  test "edits a trade with a high precise unit price" do
    trade = trades(:owner_voo_buy)
    trade.update!(unit_price: BigDecimal("1234.56789"))

    visit edit_trade_path(trade)

    assert_field "Unit price", with: "1234.56789"
  end

  test "shows edit validation errors and preserves entered values" do
    trade = trades(:owner_voo_buy)

    visit edit_trade_path(trade)
    fill_in "Quantity", with: "0"
    fill_in "Notes", with: "Keep this edited note"
    click_on "Update Trade"

    assert_text "1 error prevented this trade from being saved:"
    assert_text "Quantity must be greater than 0"
    assert_field "Quantity", with: "0"
    assert_field "Notes", with: "Keep this edited note"
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
