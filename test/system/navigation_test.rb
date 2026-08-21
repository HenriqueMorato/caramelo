require "application_system_test_case"

class NavigationTest < ApplicationSystemTestCase
  test "moves between the public foundation pages on a mobile viewport" do
    visit root_path
    page.current_window.resize_to(390, 844)

    assert_text "Dashboard"

    click_on "Transactions"

    assert_current_path transactions_path
    assert_text "No transaction tracking yet"
  end
end
