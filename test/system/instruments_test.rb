require "application_system_test_case"

class InstrumentsTest < ApplicationSystemTestCase
  test "manages a multi-currency instrument from creation through deletion" do
    visit instruments_path
    page.current_window.resize_to(390, 844)

    click_on "Add instrument"
    fill_in "Ticker", with: "aapl"
    fill_in "Name", with: "Apple Inc."
    fill_in "Currency", with: "usd"
    click_on "Create Instrument"

    assert_text "Instrument was created."
    assert_text "AAPL"
    assert_text "Apple Inc."
    assert_text "USD"
    assert_text "Trade history"

    click_on "Edit instrument"
    fill_in "Name", with: "Apple"
    click_on "Update Instrument"

    assert_text "Instrument was updated."
    assert_text "Apple"

    accept_confirm "Delete AAPL?" do
      click_on "Delete"
    end

    assert_current_path instruments_path
    assert_text "Instrument was deleted."
    assert_no_text "AAPL"
  end
end
