require "test_helper"

class MarketDataHealthControllerTest < ActionDispatch::IntegrationTest
  test "shows a read-only health report" do
    get market_data_health_url

    assert_response :success
    assert_select "h1", "Data health"
    assert_select "[role=status]"
    assert_select "form[action=?]", current_market_price_refresh_path
  end

  test "disables manual refresh during the throttle window" do
    Rails.cache.write(CurrentMarketPriceRefreshesController::MANUAL_COOLDOWN_KEY, Time.current)

    get market_data_health_url

    assert_response :success
    assert_select "button[disabled]", text: "Refresh prices"
    assert_select "[role=tooltip]", text: /once every five minutes/
  end
end
