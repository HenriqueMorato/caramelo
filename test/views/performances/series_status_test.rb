require "test_helper"

class PerformanceSeriesStatusTest < ActionView::TestCase
  test "pending history explains asynchronous calculation" do
    render_status(:pending)

    assert_select "[role=status]", /Portfolio history is building/
  end

  test "partial history does not promise that missing source data is being prepared" do
    render_status(:partial)

    assert_select "[role=status]", /One daily value is unavailable/
    assert_select "[role=status]", text: /still being prepared/, count: 0
  end

  test "stale history identifies displayed values as last calculated" do
    render_status(:stale)

    assert_select "[role=status]", /last calculated values/
  end

  test "failed history offers a retry in the same period" do
    render_status(:failed)

    assert_select "[role=alert]", /could not be updated/
    assert_select "a[href=?]", performance_path(period: "year"), "Try again"
  end

  test "source missing history is distinct from healthy history" do
    render_status(:missing)
    assert_select "[role=status]", /Historical values are incomplete/
  end

  test "healthy history adds no status banner" do
    render_status(:available)
    assert_select "[role=status]", count: 0
  end

  private

  def render_status(status)
    missing = Struct.new(:date) { def missing? = true }.new(Date.current)
    series = Performance::Series::Result.new(
      from: Date.current, to: Date.current, observations: [ missing ], status:, refresh_status: nil
    )
    render partial: "performances/series_status", locals: { series:, selected_period: "year" }
  end
end
