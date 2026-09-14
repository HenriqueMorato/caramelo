require "application_system_test_case"

class PrivacyTest < ApplicationSystemTestCase
  setup do
    page.current_window.resize_to(1280, 900)
  end

  test "back navigation cannot restore money shown before privacy was enabled" do
    visit transactions_path

    assert_text "$611.20"
    click_on "Positions"
    assert_current_path positions_path
    click_button "Hide monetary values"

    assert_button "Show monetary values"
    assert_current_path positions_path
    page.go_back

    assert_text "The trail behind the pack."
    assert_current_path transactions_path
    assert_text ApplicationHelper::MONEY_MASK
    assert_no_text "$611.20"
  end

  test "an already-open tab reloads when privacy changes" do
    visit positions_path
    original_window = current_window
    money_window = open_new_window

    within_window money_window do
      visit transactions_path
      assert_text "$611.20"
    end

    within_window original_window do
      click_button "Hide monetary values"
      assert_button "Show monetary values"
    end

    within_window money_window do
      assert_text ApplicationHelper::MONEY_MASK
      assert_no_text "$611.20"
    end
  ensure
    money_window&.close
  end
end
