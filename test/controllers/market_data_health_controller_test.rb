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
    assert_select "turbo-cable-stream-source[signed-stream-name]"
    assert_select "##{RefreshStatus::Broadcaster::ACTIVITY_TARGET}"
    assert_select "##{MarketData::HealthReportBroadcaster::TARGET}"
    assert_select "form[action=?]", current_market_price_refresh_path
  end

  test "shows an explicit empty state when a filter matches no sources" do
    report = MarketData::HealthReport::Result.new(checked_at: Time.current, entries: [])

    with_stubbed_method(MarketData::HealthReport, :for, -> { report }) do
      get market_data_health_url(status: "healthy")
    end

    assert_response :success
    assert_select "td[colspan=4]", "No sources match this filter."
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

  test "filters health entries by status" do
    healthy = MarketData::HealthReport::Entry.new(
      code: :current_price, target: MarketData::Target.new(kind: :current_price, record_id: 1),
      subject: "AAPL", status: :healthy, severity: nil, label: "AAPL", description: "ready",
      observed_on: nil, fetched_at: nil, covered_range: nil, missing_range: nil, actions: []
    )
    missing = MarketData::HealthReport::Entry.new(
      code: :missing_daily_close, target: MarketData::Target.new(kind: :daily_closing_prices, record_id: 1),
      subject: "AAPL", status: :missing, severity: :warning, label: "AAPL", description: "missing",
      observed_on: nil, fetched_at: nil, covered_range: nil, missing_range: nil, actions: [ :retry ]
    )
    report = MarketData::HealthReport::Result.new(checked_at: Time.current, entries: [ healthy, missing ])

    with_stubbed_method(MarketData::HealthReport, :for, -> { report }) do
      with_stubbed_method(MarketPrice::ManualRefresh, :call, -> { }) do
        with_stubbed_method(MarketPrice::ManualRefresh, :available?, -> { true }) do
          get market_data_health_url(status: "healthy")
        end
      end
    end

    assert_response :success
    assert_select "table[aria-label='Data health issues']" do |tables|
      assert_includes tables.to_s, "ready"
      refute_includes tables.to_s, "missing"
    end
  end

  test "filters health entries needing attention" do
    healthy = MarketData::HealthReport::Entry.new(
      code: :current_price, target: MarketData::Target.new(kind: :current_price, record_id: 1),
      subject: "AAPL", status: :healthy, severity: nil, label: "AAPL", description: "ready",
      observed_on: nil, fetched_at: nil, covered_range: nil, missing_range: nil, actions: []
    )
    missing = healthy.with(status: :missing, code: :missing_current_price, severity: :error,
      description: "missing", actions: [ :retry ])
    report = MarketData::HealthReport::Result.new(checked_at: Time.current, entries: [ healthy, missing ])

    with_stubbed_method(MarketData::HealthReport, :for, -> { report }) do
      with_stubbed_method(MarketPrice::ManualRefresh, :call, -> { }) do
        with_stubbed_method(MarketPrice::ManualRefresh, :available?, -> { true }) do
          get market_data_health_url(status: "attention")
        end
      end
    end

    assert_response :success
    assert_select "table[aria-label='Data health issues']" do |tables|
      assert_includes tables.to_s, "missing"
      refute_includes tables.to_s, "ready"
    end
  end

  test "shows ignored corporate action imports in a separate review card" do
    users(:owner).corporate_action_imports.create!(
      instrument: instruments(:petr4_bvmf), source: "yahoo_finance",
      source_reference: "health-ignored-event", status: :ignored,
      kind: "split", event_on: Date.new(2026, 8, 20)
    )
    report = MarketData::HealthReport::Result.new(checked_at: Time.current, entries: [])

    with_stubbed_method(MarketData::HealthReport, :for, -> { report }) do
      with_stubbed_method(MarketPrice::ManualRefresh, :call, -> { }) do
        with_stubbed_method(MarketPrice::ManualRefresh, :available?, -> { true }) do
          get market_data_health_url
        end
      end
    end

    assert_response :success
    assert_select "#corporate-action-import-review" do
      assert_select "h2", "Imported events"
      assert_select "p", /1 imported event was ignored/
    end
    assert_select "a[href=?]", corporate_action_imports_path(status: "ignored"), text: "Review ignored imports"
    refute_select "#health-entry-market_data_health-corporate_action_imports"
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
