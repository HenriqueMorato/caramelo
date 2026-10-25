require "application_system_test_case"

class NavigationTest < ApplicationSystemTestCase
  test "moves between the public foundation pages" do
    visit root_path

    open_menu
    assert_text "Dashboard"
    refute_link "Instruments"

    click_on "Positions"

    assert_current_path positions_path
    assert_text "Vanguard S&P 500 ETF"

    open_menu
    click_on "Transactions"

    assert_current_path transactions_path
    assert_text "Long-term allocation"
    find("summary", text: "Add").click
    assert_link "Trade"
    assert_link "Income"

    open_menu
    click_on "Dashboard"

    assert_current_path root_path
    assert_text "Portfolio value is unavailable"
  end

  test "collapses the desktop navigation into an icon rail" do
    page.current_window.resize_to(1400, 1400)
    visit root_path
    page.execute_script("localStorage.removeItem('caramelo.navigation.collapsed')")
    visit root_path

    toggle = find("aside button[data-navigation-target='toggle']")
    assert_equal "Close navigation", toggle[:"aria-label"]
    toggle.click

    assert_selector "aside.w-20"
    assert_selector "aside a[data-navigation-target='brand'].justify-center"
    assert_selector "aside nav a[href='#{root_path}'] span.sr-only", visible: false
    assert_equal "Expand navigation", find("aside button[data-navigation-target='toggle']")["aria-label"]

    visit positions_path

    assert_selector "aside.w-20"
    find("aside button[data-navigation-target='toggle']").click
    assert_selector "aside.w-52"
    assert_selector "aside a[data-navigation-target='brand'].justify-start"
  end

  private

  def open_menu
    find("summary", text: "Menu").click if page.has_css?("summary", text: "Menu", visible: true)
  end
end
