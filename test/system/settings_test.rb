require "application_system_test_case"

class SettingsTest < ApplicationSystemTestCase
  setup do
    page.current_window.resize_to(1400, 1000)
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1000)
  end

  test "saves currency preferences from the sidebar" do
    visit root_path
    page.execute_script("window.settingsDocumentMarker = 'same-document'")
    within("aside") { click_on "Settings" }
    assert_equal "same-document", page.evaluate_script("window.settingsDocumentMarker")
    choose_currency "USD"
    click_on "Save preferences"

    assert_text "Preferences saved."
    assert_select_value "USD"
    assert_equal "USD", User.owner.reporting_currency
    assert_equal "same-document", page.evaluate_script("window.settingsDocumentMarker")
    assert_button "Save preferences", disabled: false
  end

  test "shows server validation errors beside the field" do
    visit settings_path
    page.execute_script(<<~JS)
      const select = document.querySelector("#user_reporting_currency")
      select.add(new Option("Invalid currency", "BTC"))
      select.value = "BTC"
    JS
    click_on "Save preferences"

    assert_text "Reporting currency is invalid"
    assert_selector "#reporting-currency-search[aria-invalid=true]", focused: true
    assert_equal "BRL", User.owner.reporting_currency
  end

  test "filters by name and code and selects with the keyboard" do
    visit settings_path
    fill_in "Reporting currency", with: "swiss"
    assert_selector "[role=option]", count: 1, visible: true
    assert_selector "#reporting-currency-CHF", visible: true
    find("#reporting-currency-search").send_keys(:enter)
    assert_select_value "CHF"

    fill_in "Reporting currency", with: "zzzz"
    assert_text "No matching currencies."
    find("#reporting-currency-search").send_keys(:escape)
    assert_select_value "CHF"
    assert_field "Reporting currency", with: "CHF — Swiss Franc"

    fill_in "Reporting currency", with: "dollar"
    assert_selector "[role=option]", count: 4, visible: true
    find("#reporting-currency-search").send_keys(:arrow_down, :enter)
    assert_select_value "CAD"
  end

  test "debounces filtering and cancels pending work on dismissal" do
    visit settings_path
    find("#reporting-currency-search").click
    result = page.evaluate_script(<<~JS)
      (() => {
        const input = document.querySelector("#reporting-currency-search")
        input.value = "euro"
        input.dispatchEvent(new Event("input", { bubbles: true }))
        return [...document.querySelectorAll('[role="option"]')].filter(option => !option.hidden).length
      })()
    JS
    assert_equal ReportingCurrency::SUPPORTED_CODES.size, result
    assert_selector "[role=option]", count: 1, visible: true
    fill_in "Reporting currency", with: "dollar"
    find("#reporting-currency-search").send_keys(:tab)
    assert_selector "#reporting-currency-search[aria-expanded=false]"
    assert_select_value "BRL"
  end

  test "arrow navigation applies a pending search before selecting" do
    visit settings_path
    find("#reporting-currency-search").click
    page.execute_script(<<~JS)
      const input = document.querySelector("#reporting-currency-search")
      input.value = "EUR"
      input.dispatchEvent(new Event("input", { bubbles: true }))
      for (const key of ["ArrowDown", "Enter"]) {
        input.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }))
      }
    JS
    assert_select_value "EUR"
  end

  test "warns before discarding an unsaved preference" do
    visit settings_path
    choose_currency "EUR"

    dismiss_confirm "Discard your unsaved currency preference?" do
      within("aside") { click_on "Positions" }
    end
    assert_current_path settings_path
    assert_select_value "EUR"

    accept_confirm "Discard your unsaved currency preference?" do
      within("aside") { click_on "Positions" }
    end
    assert_current_path positions_path
    assert_equal "BRL", User.owner.reporting_currency
  end

  test "Back and Forward restore an unsaved selection without treating it as saved" do
    visit root_path
    within("aside") { click_on "Settings" }
    choose_currency "EUR"
    assert_select_value "EUR"

    page.go_back
    assert_current_path root_path
    page.go_forward
    assert_current_path settings_path
    assert_select_value "EUR"
    assert_equal "BRL", User.owner.reporting_currency

    dismiss_confirm "Discard your unsaved currency preference?" do
      within("aside") { click_on "Positions" }
    end
    assert_current_path settings_path
    assert_button "Save preferences", disabled: false
  end

  test "fits mobile and desktop layouts and exposes Settings in the mobile menu" do
    visit settings_path
    [ [ 390, 844 ], [ 1280, 900 ], [ 1920, 1080 ] ].each do |width, height|
      page.current_window.resize_to(width, height)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width:, height:, deviceScaleFactor: 1, mobile: false)
      assert_selector "h1", text: "Settings"
      assert_selector "#reporting-currency-search", visible: true
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
      page.save_screenshot(Rails.root.join("tmp", "settings-#{width}.png"))
      find("#reporting-currency-search").click
      page.save_screenshot(Rails.root.join("tmp", "settings-picker-#{width}.png"))
      find("#reporting-currency-search").send_keys(:escape)
    end
    page.current_window.resize_to(390, 844)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: false)
    find("summary", text: "Menu").click
    within("header nav") { assert_link "Settings", href: settings_path }
  end

  test "unsaved preference cancels native unloading" do
    visit root_path
    within("aside") { click_on "Settings" }
    choose_currency "EUR"

    # HTTP-only WebDriver suppresses beforeunload prompts; assert cancellation instead.
    assert page.evaluate_script(<<~JS)
      (() => {
        const event = new Event("beforeunload", { cancelable: true })
        window.dispatchEvent(event)
        return event.defaultPrevented
      })()
    JS
    choose_currency "BRL"
    assert_not page.evaluate_script(<<~JS)
      (() => {
        const event = new Event("beforeunload", { cancelable: true })
        window.dispatchEvent(event)
        return event.defaultPrevented
      })()
    JS
  end

  private

  def choose_currency(code)
    fill_in "Reporting currency", with: code
    find("#reporting-currency-#{code}", visible: true).click
  end

  def assert_select_value(value)
    assert_equal value, find("#user_reporting_currency", visible: false).value
  end
end
