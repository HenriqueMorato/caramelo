require "test_helper"

class RefreshStatus::PresenterTest < ActiveSupport::TestCase
  Refresh = Data.define(:finished_at, :started_at, :scope, :status, :processed_count, :total_count) do
    def progress_label
      total_count && "#{processed_count}/#{total_count}"
    end
  end

  setup do
    Rails.cache.clear
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
    refute presenter.completed_refresh?
  end

  test "identifies aggregate current-price refreshes" do
    refresh = Refresh.new(started_at: 1.minute.ago, finished_at: nil, scope: RefreshStatus::MARKET_PRICE_SCOPE, status: "running",
      processed_count: 0, total_count: 2)
    presenter = RefreshStatus::Presenter.new(active_refresh: refresh, last_successful_refresh_at: nil,
      latest_failed_refresh: nil)

    assert presenter.current_prices_updating?
  end

  test "summarizes concurrent operations without switching between their progress" do
    refresh = Refresh.new(started_at: 1.minute.ago, finished_at: nil, scope: "prices", status: "running",
      processed_count: 1, total_count: 2)
    presenter = RefreshStatus::Presenter.new(
      active_refresh: refresh, active_count: 3, last_successful_refresh_at: nil, latest_failed_refresh: nil
    )

    assert_equal "3 active", presenter.progress_label
  end

  test "stays active while the health report has rebuilding sources" do
    entry = Struct.new(:updating?).new(true)
    report = Struct.new(:entries).new([ entry, entry ])

    presenter = RefreshStatus::Presenter.for(report:)

    assert_predicate presenter, :updating?
    assert_equal 2, presenter.active_count
    assert_equal "2 active", presenter.progress_label
  end

  test "identifies a completed aggregate current-price refresh" do
    refresh = Refresh.new(started_at: 1.minute.ago, finished_at: Time.current, scope: RefreshStatus::MARKET_PRICE_SCOPE, status: "succeeded",
      processed_count: 2, total_count: 2)
    presenter = RefreshStatus::Presenter.new(active_refresh: nil, last_successful_refresh_at: refresh.finished_at,
      latest_successful_refresh: refresh, latest_failed_refresh: nil)

    assert presenter.completed_refresh?
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

  test "prunes expired dynamic scopes before presenting global activity" do
    travel_to 11.minutes.ago do
      RefreshStatus::State.write(scope: "expired_presenter_scope", status: "succeeded", finished_at: Time.current)
    end

    RefreshStatus::Presenter.for

    refute_includes RefreshStatus::State.scopes, "expired_presenter_scope"
  end
end
