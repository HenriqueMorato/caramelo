require "application_system_test_case"

class AssetTypesTest < ApplicationSystemTestCase
  test "creates and renames a custom asset type" do
    visit asset_types_path
    click_on "Add asset type"

    fill_in "Name", with: "Real estate"
    click_on "Create asset type"

    assert_text "Real estate"
    within "#asset_type_#{AssetType.find_by!(key: "real_estate").id}" do
      click_on "Edit"
    end

    fill_in "Name", with: "Property"
    click_on "Update asset type"

    assert_text "Property"
    assert_no_text "Real estate"
  end

  test "opens asset type management from data health" do
    visit market_data_health_path
    click_on "Manage asset types"

    assert_current_path asset_types_path
    assert_text "Asset types"
  end
end
