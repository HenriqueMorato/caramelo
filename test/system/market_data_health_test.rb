require "application_system_test_case"

class MarketDataHealthTest < ApplicationSystemTestCase
  setup do
    Rails.cache.clear
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
  end

  test "keeps health filters and live row updates available" do
    visit market_data_health_path

    assert_text "Data health"
    assert_selector "turbo-cable-stream-source[signed-stream-name]", visible: false
    assert_selector "#notification-stack.absolute"
    assert_selector "form[action='/market-data/recoveries'][data-turbo-stream='true']"
    assert_link "Needs attention", href: market_data_health_path(status: "attention")
    assert_link "Healthy", href: market_data_health_path(status: "healthy")

    click_link "Needs attention", href: market_data_health_path(status: "attention")

    assert_current_path market_data_health_path(status: "attention")
    assert_text "Needs attention"
  end

  test "updates refresh progress without replacing its activity surface" do
    Rails.cache.write(MarketPrice::ManualRefresh::COOLDOWN_KEY, "system-test")
    state = RefreshStatus::State.write(
      scope: "system_progress", run_id: "system-run", status: "running",
      started_at: Time.current, processed_count: 0, total_count: 2
    )
    visit market_data_health_path

    assert_text "Market data updating…"
    assert_text "0/2"
    page.execute_script("window.healthActivityNode = document.querySelector('#health-refresh-activity')")

    state = RefreshStatus::State.write(
      scope: state.scope, run_id: state.run_id, status: "running", started_at: state.started_at,
      processed_count: 1, total_count: 2
    )
    RefreshStatus::Broadcaster.refresh(state:, health: false)

    assert_text "1/2"
    assert page.evaluate_script(
      "window.healthActivityNode === document.querySelector('#health-refresh-activity')"
    )
    completed = RefreshStatus::State.write(
      scope: state.scope, run_id: state.run_id, status: "succeeded", started_at: state.started_at,
      finished_at: Time.current, processed_count: 2, total_count: 2
    )
    RefreshStatus::Broadcaster.refresh(state: completed, health: false)

    assert_no_text "Market data updating…"
    assert_text "Market data updated"
  end

  test "replacement preview is keyboard-dismissible and mobile-safe" do
    page.current_window.resize_to(390, 844)
    visit market_data_health_path
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: false)

    first("summary", text: "Replace…").click
    assert_text "Review data replacement"

    page.send_keys(:escape)

    assert_no_selector "details[open]"
    assert_equal "Replace…", page.evaluate_script("document.activeElement.textContent.trim()")
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=,
      page.evaluate_script("window.innerWidth")
  end
end
