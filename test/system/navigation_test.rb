require "application_system_test_case"

class NavigationTest < ApplicationSystemTestCase
  test "moves between the public foundation pages" do
    visit root_path

    open_menu
    assert_text "Dashboard"

    click_on "Positions"

    assert_current_path positions_path
    assert_text "Vanguard S&P 500 ETF"

    open_menu
    click_on "Transactions"

    assert_current_path transactions_path
    assert_text "Long-term allocation"

    open_menu
    click_on "Dashboard"

    assert_current_path root_path
    assert_text "Portfolio value is unavailable"
  end

  private

  def open_menu
    find("summary", text: "Menu").click if page.has_css?("summary", text: "Menu", visible: true)
  end
end
