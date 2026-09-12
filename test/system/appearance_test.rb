require "application_system_test_case"

class AppearanceTest < ApplicationSystemTestCase
  setup do
    page.current_window.resize_to(1400, 1000)
    visit root_path
    page.execute_script("localStorage.clear()")
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
  end

  test "defaults to the system theme and follows system changes" do
    emulate_color_scheme("dark")
    visit settings_path

    assert_theme appearance: "system", theme: "dark"

    emulate_color_scheme("light")
    assert_theme appearance: "system", theme: "light"
  end

  test "an explicit preference overrides the system and persists across Turbo visits" do
    emulate_color_scheme("light")
    visit settings_path

    within("[aria-labelledby=appearance-heading]") { click_button "Dark" }
    assert_theme appearance: "dark", theme: "dark"
    assert_equal "dark", page.evaluate_script("localStorage.getItem('caramelo.appearance')")
    assert_selector "button[data-appearance-mode=dark][aria-pressed=true]", count: 3, visible: :all
    refresh
    assert_theme appearance: "dark", theme: "dark"

    within("aside") { click_on "Positions" }
    assert_current_path positions_path
    assert_theme appearance: "dark", theme: "dark"

    within("aside") do
      find("summary", text: "Appearance").click
      click_button "Light"
    end
    assert_theme appearance: "light", theme: "light"
  end

  test "system mode resumes live operating-system tracking" do
    emulate_color_scheme("dark")
    visit settings_path
    within("[aria-labelledby=appearance-heading]") { click_button "Light" }

    emulate_color_scheme("dark")
    assert_theme appearance: "light", theme: "light"

    within("[aria-labelledby=appearance-heading]") { click_button "System" }
    assert_theme appearance: "system", theme: "dark"
  end

  test "sidebar appearance menu closes after outside clicks but stays open during selection" do
    visit settings_path

    within("aside") { find("summary", text: "Appearance").click }
    assert_selector "aside details[data-appearance-target=menu][open]"
    find("body").send_keys(:escape)
    assert_no_selector "aside details[data-appearance-target=menu][open]"

    within("aside") { find("summary", text: "Appearance").click }
    find("h1", text: "Settings").click
    assert_no_selector "aside details[data-appearance-target=menu][open]"

    within("aside") do
      find("summary", text: "Appearance").click
      click_button "Dark"
    end
    assert_selector "aside details[data-appearance-target=menu][open]"
  end

  test "invalid stored preferences safely fall back to system" do
    emulate_color_scheme("dark")
    visit settings_path
    page.execute_script("localStorage.setItem('caramelo.appearance', 'sepia')")
    refresh

    assert_theme appearance: "system", theme: "dark"
  end

  test "preferences synchronize between open tabs" do
    visit settings_path
    original_window = page.current_window
    second_window = open_new_window

    within_window(second_window) do
      visit settings_path
      within("[aria-labelledby=appearance-heading]") { click_button "Dark" }
      assert_theme appearance: "dark", theme: "dark"
    end

    within_window(original_window) do
      assert_theme appearance: "dark", theme: "dark"
    end
  end

  test "migrates the legacy appearance preference" do
    page.execute_script("localStorage.setItem('local_folio.appearance', 'dark')")
    visit settings_path

    assert_theme appearance: "dark", theme: "dark"
    assert_equal "dark", page.evaluate_script("localStorage.getItem('caramelo.appearance')")
    assert_nil page.evaluate_script("localStorage.getItem('local_folio.appearance')")
  end

  private

  def emulate_color_scheme(value)
    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia",
      features: [ { name: "prefers-color-scheme", value: } ]
    )
  end

  def assert_theme(appearance:, theme:)
    assert_selector "html[data-appearance='#{appearance}'][data-theme='#{theme}']", visible: :all
    assert_equal theme, page.evaluate_script("document.documentElement.style.colorScheme")
    assert_equal(theme == "dark" ? "#17120f" : "#f6efe4",
      page.evaluate_script("document.querySelector('meta[name=theme-color]').content"))
  end
end
