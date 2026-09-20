require "application_system_test_case"

class CorporateActionsTest < ApplicationSystemTestCase
  setup do
    CorporateAction.delete_all
    page.current_window.resize_to(1400, 1400)
    visit root_path
    click_button "Show monetary values" if page.has_button?("Show monetary values", wait: 0)
  end

  test "records income from an instrument without linking a reinvestment trade" do
    instrument = instruments(:petr4_bvmf)
    trade = trades(:owner_voo_buy).dup
    trade.instrument = instrument
    trade.institution = institutions(:owner_xp)
    trade.currency = instrument.currency
    trade.slug = nil
    trade.save!
    visit instrument_path(instrument)

    within("[aria-labelledby='activity-history-heading']") do
      find("summary", text: "Add").click
      within("details[data-testid='add-instrument-transaction-menu']") do
        click_on "Income"
      end
    end

    select "JCP", from: "Action type"
    assert_no_field "Institution (optional)"
    assert_text "If blank, payment date is used instead."
    set_date("corporate_action_paid_on", "2026-08-25")
    set_date("corporate_action_ex_date", "2026-08-20")
    fill_in "Gross amount", with: "12.34"
    fill_in "Withholding tax", with: "1.85"
    fill_in "Notes", with: "Quarterly payout"

    click_button "Save income"

    assert_current_path transactions_path
    assert_text "JCP"
    assert_text "R$10,49"
    within "#corporate_action_#{CorporateAction.last.id}" do
      click_on "Petrobras PN"
    end
    assert_current_path instrument_path(instrument)
    within "#corporate_action_#{CorporateAction.last.id}" do
      assert_text "Quarterly payout"
      assert_link "Edit"
      assert_button "Delete"
      click_on "Edit"
    end
    assert_equal institutions(:owner_xp), CorporateAction.last.institution
    assert_equal Date.new(2026, 8, 20), CorporateAction.last.ex_date
    assert_equal 0, CorporateAction.last.instrument.trades.where(traded_on: Date.new(2026, 8, 25)).count

    fill_in "Notes", with: "Updated payout"
    click_button "Save income"

    assert_current_path instrument_path(instrument)
    corporate_action_id = CorporateAction.last.id
    within "#corporate_action_#{corporate_action_id}" do
      assert_text "Updated payout"
      accept_confirm "Delete this income event?" do
        click_on "Delete"
      end
    end
    assert_current_path instrument_path(instrument)
    assert_no_selector "#corporate_action_#{corporate_action_id}"
  end

  test "keeps income private across navigation" do
    create_action
    visit transactions_path(activity: "income")

    assert_text "R$10,49"
    click_button "Hide monetary values"

    assert_text ApplicationHelper::MONEY_MASK
    assert_no_text "R$10,49"
    click_on "Petrobras PN"
    assert_text ApplicationHelper::MONEY_MASK
  end

  test "warns before discarding unsaved income" do
    visit new_corporate_action_path
    fill_in "Notes", with: "Unsaved note"

    dismiss_confirm "Discard your unsaved income changes?" do
      click_on "Cancel"
    end
    assert_current_path new_corporate_action_path

    accept_confirm "Discard your unsaved income changes?" do
      click_on "Cancel"
    end
    assert_current_path transactions_path
  end

  private

  def set_date(id, value)
    page.execute_script(<<~JS, id, value)
      const field = document.getElementById(arguments[0])
      field.value = arguments[1]
      field.dispatchEvent(new Event("input", { bubbles: true }))
      field.dispatchEvent(new Event("change", { bubbles: true }))
    JS
  end

  def create_action
    CorporateAction.create!(
      user: users(:owner), instrument: instruments(:petr4_bvmf), kind: :dividend,
      status: :confirmed, paid_on: Date.new(2026, 8, 25), gross_amount_cents: 1_234,
      withholding_tax_cents: 185, net_amount_cents: 1_049, currency: "BRL", source: "manual"
    )
  end
end
