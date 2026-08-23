require "application_system_test_case"

class InstitutionsTest < ApplicationSystemTestCase
  test "manages an institution from creation through deletion" do
    visit institutions_path
    page.current_window.resize_to(390, 844)

    click_on "Add institution"
    fill_in "Name", with: "BTG Pactual"
    fill_in "Notes", with: "Long-term investments"
    click_on "Create Institution"

    assert_text "Institution was created."
    assert_text "BTG Pactual"
    assert_text "Long-term investments"

    click_on "Edit institution"
    fill_in "Notes", with: "Updated investment notes"
    uncheck "Active"
    click_on "Update Institution"

    assert_text "Institution was updated."
    assert_text "Updated investment notes"
    assert_text "Inactive"

    click_on "Edit institution"
    check "Active"
    click_on "Update Institution"

    assert_text "Active"

    accept_confirm "Delete BTG Pactual?" do
      click_on "Delete"
    end

    assert_current_path institutions_path
    assert_text "Institution was deleted."
    assert_no_text "BTG Pactual"
  end
end
