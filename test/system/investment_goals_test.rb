require "application_system_test_case"

class InvestmentGoalsTest < ApplicationSystemTestCase
  test "creates, edits, pauses, and resumes a portfolio value goal" do
    visit investment_goals_path
    first("a", text: "Add investment goal").click

    fill_in "Target portfolio value", with: "1000000"
    fill_in "Target date", with: (Date.current + 1.year).strftime("%Y-%m-%d")
    click_on "Create investment goal"

    assert_current_path investment_goals_path
    assert_text "R$1.000.000,00"
    assert_text "Active"

    click_on "Edit"
    fill_in "Target portfolio value", with: "1200000"
    click_on "Update investment goal"
    assert_text "R$1.200.000,00"

    click_on "Pause"
    assert_text "Paused"
    click_on "Resume"
    assert_text "Active"
  end

  test "shows a goal setup card on the dashboard" do
    visit root_path

    assert_text "Give your portfolio a destination"
    click_on "Set a goal"

    assert_current_path new_investment_goal_path
    assert_selector "h1", text: "Add investment goal"
  end
end
