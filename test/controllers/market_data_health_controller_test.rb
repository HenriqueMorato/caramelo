require "test_helper"

class MarketDataHealthControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
  end

  test "shows the health report and refresh controls" do
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

  test "starts a refresh when health issues are detected" do
    calls = 0
    with_stubbed_method(RefreshTradedMarketPricesJob, :enqueue_for, -> { calls += 1 }) do
      get market_data_health_url
    end

    assert_response :success
    assert_equal 1, calls
  end

  test "does not repeat an automatic refresh during the cooldown window" do
    Rails.cache.write(CurrentMarketPriceRefreshesController::MANUAL_COOLDOWN_KEY, Time.current)
    calls = 0

    with_stubbed_method(RefreshTradedMarketPricesJob, :enqueue_for, -> { calls += 1 }) do
      get market_data_health_url
    end

    assert_response :success
    assert_equal 0, calls
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, &replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
