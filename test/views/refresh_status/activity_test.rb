require "test_helper"

class RefreshStatusActivityTest < ActionView::TestCase
  Status = Struct.new(:updating, :failed, :progress_label, :last_successful_refresh_at) do
    def updating? = updating
    def failed? = failed
  end

  test "shows stable progress with a numeric label" do
    render_activity(Status.new(true, false, "2/6", nil))

    assert_select "##{RefreshStatus::Broadcaster::ACTIVITY_TARGET}[aria-live=polite]", /Market data updating/
    assert_select ".tabular-nums", "2/6"
  end

  test "supports active work without a known total" do
    render_activity(Status.new(true, false, nil, nil))

    assert_select "#health-refresh-progress"
    refute_match(/\d+\/\d+/, rendered)
  end

  test "shows the latest failure" do
    render_activity(Status.new(false, true, nil, nil))

    assert_select "##{RefreshStatus::Broadcaster::ACTIVITY_TARGET}", /needs attention/
  end

  test "shows the latest successful refresh time" do
    render_activity(Status.new(false, false, nil, Time.current))

    assert_select "##{RefreshStatus::Broadcaster::ACTIVITY_TARGET}", /Market data updated/
  end

  test "remains empty without refresh history" do
    render_activity(Status.new(false, false, nil, nil))

    assert_select "##{RefreshStatus::Broadcaster::ACTIVITY_TARGET} > *", count: 0
  end

  private

  def render_activity(status)
    render partial: "refresh_status/activity", locals: { status: }
  end
end
