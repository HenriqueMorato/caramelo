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

  test "filters searchable options with a debounced query" do
    find("#trade_instrument_id-button").click
    assert_selector "#trade_instrument_id-search", visible: true
    assert_selector "#trade_instrument_id-search[role='combobox'][aria-expanded='true'][aria-controls='trade_instrument_id-listbox']"
    assert_includes find("#trade_instrument_id-search")["aria-labelledby"], "trade_instrument_id-label"
    assert_includes find("#trade_instrument_id-search")["aria-describedby"], "trade_instrument_id-search-hint"
    assert_selector "#trade_instrument_id-button:not([role='combobox'])"

    fill_in "trade_instrument_id-search", with: "VOO"

    assert_selector "#trade_instrument_id-listbox [role='option']", text: "VOO · ARCX", visible: true
    assert_no_selector "#trade_instrument_id-listbox [role='option']", text: "PETR4 · BVMF", visible: true

    find("#trade_instrument_id-listbox [role='option']", text: "VOO · ARCX", visible: true).click
    assert_caramelo_select_value "VOO · ARCX — Vanguard S&P 500 ETF", from: "Instrument *"
    assert_selector "#trade_instrument_id-search[hidden]", visible: :all
    assert_selector "#trade_instrument_id-search-hint[hidden]", visible: :all
  end

  test "moves required and validation state to the focused search field" do
    find("#trade_instrument_id-button").click

    assert_selector "#trade_instrument_id-search[aria-required='true']"
    assert_includes find("#trade_instrument_id-search")["aria-describedby"], "trade_instrument_id-error"
    assert_selector "#trade_instrument_id-search-hint:not([hidden])", visible: :all

    page.execute_script("document.getElementById('trade_instrument_id').dispatchEvent(new Event('invalid', { bubbles: true, cancelable: true }))")

    assert_selector "#trade_instrument_id-search[aria-invalid='true']"
    assert_selector "#trade_instrument_id-button:not([aria-invalid])"
  end

  test "commits the first matching option before the debounce completes" do
    find("#trade_instrument_id-button").click

    page.execute_script(<<~JS)
      const input = document.querySelector("#trade_instrument_id-search")
      input.value = "VOO"
      input.dispatchEvent(new Event("input", { bubbles: true }))
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }))
    JS

    assert_caramelo_select_value "VOO · ARCX — Vanguard S&P 500 ETF", from: "Instrument *"
  end

  test "restores focus when a searchable picker closes with Tab or outside click" do
    trigger = find("#trade_instrument_id-button")
    trigger.click
    find("#trade_instrument_id-search").send_keys(:tab)
    assert_selector "#trade_instrument_id-button:focus"

    trigger.click
    page.execute_script(<<~JS)
      document.getElementById("trade_instrument_id-search").dispatchEvent(
        new KeyboardEvent("keydown", { key: "Tab", shiftKey: true, bubbles: true, cancelable: true })
      )
    JS
    assert_selector "#trade_instrument_id-button:focus"

    trigger.click
    find("h1").click
    assert_selector "#trade_instrument_id-button:focus"
  end

  test "announces when a search has no matching options outside the listbox" do
    find("#trade_instrument_id-button").click
    fill_in "trade_instrument_id-search", with: "zzzz"

    assert_selector "#trade_instrument_id-no-results[role='status']", text: "No matching options", visible: true
    assert_selector "#trade_instrument_id-listbox[hidden]", visible: :all
    assert_no_selector "#trade_instrument_id-listbox [role='status']"
    assert_includes find("#trade_instrument_id-search")["aria-describedby"], "trade_instrument_id-no-results"
  end

  test "keeps an empty-state message hidden until the picker opens" do
    page.execute_script(<<~JS)
      const select = document.querySelector("#trade_instrument_id")
      for (const option of select.options) option.disabled = true
    JS
    assert_selector "#trade_instrument_id-no-results[hidden]", visible: :all

    find("#trade_instrument_id-button").click

    assert_selector "#trade_instrument_id-no-results[role='status']", text: "No options available", visible: true
    assert_selector "#trade_instrument_id-listbox[hidden]", visible: :all
    find("#trade_instrument_id-search").send_keys(:escape)
    assert_selector "#trade_instrument_id-no-results[hidden]", visible: :all
  end

  test "does not expose hidden native options in the custom listbox" do
    find("#trade_instrument_id-button").click
    page.execute_script(<<~JS)
      const select = document.getElementById("trade_instrument_id")
      const option = [...select.options].find(candidate => candidate.textContent.includes("VOO · ARCX"))
      option.hidden = true
    JS

    assert_no_selector "#trade_instrument_id-listbox [role='option']", text: "VOO · ARCX", visible: true
  end

  test "syncs the custom value after a native input event" do
    page.execute_script(<<~JS)
      const select = document.getElementById("trade_instrument_id")
      const option = [...select.options].find(candidate => candidate.textContent.includes("VOO · ARCX"))
      select.value = option.value
      select.dispatchEvent(new Event("input"))
    JS

    assert_caramelo_select_value "VOO · ARCX — Vanguard S&P 500 ETF", from: "Instrument *"
  end

  test "preserves a native accessible name when enhancing the select" do
    page.execute_script(<<~JS)
      const select = document.getElementById("trade_instrument_id")
      const label = document.createElement("span")
      label.id = "external-instrument-label"
      label.textContent = "External instrument label"
      document.body.append(label)
      select.setAttribute("aria-labelledby", label.id)
    JS

    assert_selector "#trade_instrument_id-button[aria-labelledby~='external-instrument-label']"
    assert_selector "#trade_instrument_id-listbox[aria-labelledby~='external-instrument-label']", visible: :all

    find("#trade_instrument_id-button").click
    assert_selector "#trade_instrument_id-search[aria-labelledby~='external-instrument-label']", visible: true

    page.execute_script("document.getElementById('trade_instrument_id').removeAttribute('aria-labelledby')")
    assert_selector "#trade_instrument_id-button[aria-labelledby~='trade_instrument_id-label']"

    page.execute_script("document.getElementById('trade_instrument_id').setAttribute('aria-label', 'Native instrument name')")
    assert_selector "#trade_instrument_id-button[aria-label='Native instrument name']"
    assert_no_selector "#trade_instrument_id-button[aria-labelledby]"
  end

  test "moves focus when an open picker becomes disabled" do
    find("#trade_instrument_id-button").click
    page.execute_script("document.getElementById('trade_instrument_id').disabled = true")

    assert page.evaluate_script("document.activeElement && document.activeElement.id !== 'trade_instrument_id-search' && document.activeElement.id !== 'trade_instrument_id-button'")
    assert_selector "#trade_instrument_id-button[disabled]", visible: :all
  end

  test "hides the custom picker when the native select is hidden" do
    page.execute_script("document.getElementById('trade_instrument_id').hidden = true")

    assert page.evaluate_script("document.getElementById('trade_instrument_id').previousElementSibling.hidden")
  end

  test "moves focus when a closed trigger becomes disabled" do
    page.execute_script("document.getElementById('trade_instrument_id-button').focus()")
    page.execute_script("document.getElementById('trade_instrument_id').disabled = true")

    assert_selector "#trade_instrument_id-button[disabled]", visible: :all
    refute_equal "trade_instrument_id-button", page.evaluate_script("document.activeElement ? document.activeElement.id : null")
  end

  test "moves focus when a closed trigger becomes hidden" do
    page.execute_script("document.getElementById('trade_instrument_id-button').focus()")
    page.execute_script("document.getElementById('trade_instrument_id').hidden = true")

    assert page.evaluate_script("document.getElementById('trade_instrument_id').previousElementSibling.hidden")
    refute_equal "trade_instrument_id-button", page.evaluate_script("document.activeElement ? document.activeElement.id : null")
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
