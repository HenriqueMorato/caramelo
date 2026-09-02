require "test_helper"

class MarketDataHealthControllerTest < ActionDispatch::IntegrationTest
  test "shows a read-only health report" do
    get market_data_health_url

    assert_response :success
    assert_select "h1", "Data health"
    assert_select "[role=status]"
  end
end
