require "application_system_test_case"

class NavigationTest < ApplicationSystemTestCase
  test "moves between the public foundation pages on a mobile viewport" do
    visit root_path
    page.current_window.resize_to(390, 844)

    assert_text "Dashboard"

    click_on "Transactions"

    assert_current_path transactions_path
    assert_text "No transaction tracking yet"

    click_on "Dashboard"

    assert_current_path root_path
    assert_text "Your portfolio overview will live here"
  end
end
