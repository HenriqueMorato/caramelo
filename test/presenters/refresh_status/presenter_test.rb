require "test_helper"

class RefreshStatus::PresenterTest < ActiveSupport::TestCase
  Refresh = Data.define(:finished_at, :started_at, :scope, :status, :processed_count, :total_count) do
    def progress_label
      total_count && "#{processed_count}/#{total_count}"
    end
  end

  test "reports an active refresh and its progress" do
    refresh = Refresh.new(started_at: 1.minute.ago, finished_at: nil, scope: "prices", status: "running",
      processed_count: 1, total_count: 2)
    presenter = RefreshStatus::Presenter.new(active_refresh: refresh, last_successful_refresh_at: nil,
      latest_failed_refresh: nil)

    assert presenter.updating?
    refute presenter.current_prices_updating?
    assert_equal "1/2", presenter.progress_label
    refute presenter.failed?
  end

  test "identifies aggregate current-price refreshes" do
    refresh = Refresh.new(started_at: 1.minute.ago, finished_at: nil, scope: "manual_current_market_prices", status: "running",
      processed_count: 0, total_count: 2)
    presenter = RefreshStatus::Presenter.new(active_refresh: refresh, last_successful_refresh_at: nil,
      latest_failed_refresh: nil)

    assert presenter.current_prices_updating?
  end

  test "reports a failure newer than the last successful refresh" do
    success_at = 1.hour.ago
    failure = Refresh.new(started_at: 2.minutes.ago, finished_at: Time.current, scope: "prices", status: "failed",
      processed_count: 0, total_count: nil)
    presenter = RefreshStatus::Presenter.new(active_refresh: nil, last_successful_refresh_at: success_at,
      latest_failed_refresh: failure)

    assert presenter.failed?
    refute presenter.updating?
    assert_nil presenter.progress_label
  end

  test "does not report an older failure after a successful refresh" do
    failure = Refresh.new(started_at: 2.hours.ago, finished_at: 1.hour.ago, scope: "prices", status: "failed",
      processed_count: 0, total_count: nil)
    presenter = RefreshStatus::Presenter.new(active_refresh: nil, last_successful_refresh_at: Time.current,
      latest_failed_refresh: failure)

    refute presenter.failed?
  end
end
