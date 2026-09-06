require "application_system_test_case"

class MarketDataHealthTest < ApplicationSystemTestCase
  test "keeps health filters and live row updates available" do
    visit market_data_health_path

    assert_text "Data health"
    assert_selector "turbo-cable-stream-source[signed-stream-name]", visible: false
    assert_selector "#notification-stack.absolute"
    assert_selector "form[action='/market-data/recoveries'][data-turbo-stream='true']"
    assert_link "Needs attention", href: market_data_health_path(status: "attention")
    assert_link "Healthy", href: market_data_health_path(status: "healthy")

    click_on "Needs attention"

    assert_current_path market_data_health_path(status: "attention")
    assert_text "Needs attention"
  end
end
