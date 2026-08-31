require "application_system_test_case"

class NavigationTest < ApplicationSystemTestCase
  test "moves between the public foundation pages on a mobile viewport" do
    visit root_path
    page.current_window.resize_to(390, 844)

    assert_text "Dashboard"

    click_on "Positions"

    assert_current_path positions_path
    assert_text "Vanguard S&P 500 ETF"

    click_on "Transactions"

    assert_current_path transactions_path
    assert_text "Long-term allocation"

    click_on "Dashboard"

    assert_current_path root_path
    assert_text "Portfolio value is unavailable"
  end
end
