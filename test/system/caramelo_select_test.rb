require "application_system_test_case"

class CarameloSelectTest < ApplicationSystemTestCase
  setup do
    visit new_trade_path
  end

  test "opens, navigates, and commits with the keyboard" do
    trigger = find("#trade_side-button")

    assert_selector "#trade_side-button[role='combobox'][aria-autocomplete='none']"
    assert_includes trigger["aria-labelledby"], "trade_side-label"
    assert_includes trigger["aria-labelledby"], "trade_side-value"

    trigger.send_keys(:space)
    assert_selector "#trade_side-listbox[aria-hidden='false']", visible: true

    trigger.send_keys(:arrow_down, :enter)

    assert_caramelo_select_value "Sell", from: "Side *"
    assert_selector "#trade_side-button[aria-expanded='false']"
    assert_selector "#trade_side-button:focus"
  end

  test "dismisses on Escape and outside clicks without changing the value" do
    trigger = find("#trade_side-button")

    trigger.click
    assert_selector "#trade_side-listbox[aria-hidden='false']", visible: true
    trigger.send_keys(:escape)

    assert_caramelo_select_value "Buy", from: "Side *"
    assert_selector "#trade_side-button[aria-expanded='false']"

    trigger.click
    find("h1").click

    assert_caramelo_select_value "Buy", from: "Side *"
    assert_selector "#trade_side-button[aria-expanded='false']"
  end

  test "shows a visible validation message when a required select is blank" do
    click_on "Create Trade"

    assert_selector "#trade_instrument_id-button[aria-invalid='true']:focus"
    assert_selector "#trade_instrument_id-error:not([hidden])", text: "Please select an option."
  end

  test "focuses the first invalid custom select" do
    page.execute_script("document.getElementById('trade_side').selectedIndex = -1")

    click_on "Create Trade"

    assert_selector "#trade_instrument_id-button[aria-invalid='true']:focus"
    assert_selector "#trade_instrument_id-error:not([hidden])", text: "Please select an option."
    assert_selector "#trade_side-error:not([hidden])", text: "Please select an option."
  end
end
