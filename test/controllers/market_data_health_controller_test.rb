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
    Rails.cache.write(MarketPrice::ManualRefresh::COOLDOWN_KEY, Time.current)

    get market_data_health_url

    assert_response :success
    assert_select "button[disabled]", text: "Refresh prices"
    assert_select "[role=tooltip]", text: /once every five minutes/
  end

  test "starts a refresh when health issues are detected" do
    calls = 0
    report = MarketData::HealthReport::Result.new(
      checked_at: Time.current,
      issues: [ MarketData::HealthReport::Issue.new(
        code: :missing_current_price, severity: :error, subject: "PETR4", details: "missing"
      ) ]
    )
    with_stubbed_method(MarketData::HealthReport, :for, -> { report }) do
      with_stubbed_method(MarketPrice::ManualRefresh, :call, -> { calls += 1 }) do
        get market_data_health_url
      end
    end

    assert_response :success
    assert_equal 1, calls
  end

  test "delegates cooldown enforcement to the refresh service" do
    Rails.cache.write(MarketPrice::ManualRefresh::COOLDOWN_KEY, Time.current)
    calls = 0

    with_stubbed_method(MarketPrice::ManualRefresh, :call, -> { calls += 1 }) do
      get market_data_health_url
    end

    assert_response :success
    assert_equal 1, calls
  end

  test "does not refresh when current prices are healthy" do
    report = MarketData::HealthReport::Result.new(checked_at: Time.current, issues: [])
    calls = 0

    with_stubbed_method(MarketData::HealthReport, :for, -> { report }) do
      with_stubbed_method(MarketPrice::ManualRefresh, :call, -> { calls += 1 }) do
        get market_data_health_url
      end
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
