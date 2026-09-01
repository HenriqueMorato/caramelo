require "test_helper"

class Performance::SeriesPresenterTest < ActiveSupport::TestCase
  test "uses compact dates within one year" do
    series = series_with(Date.new(2026, 8, 15), Date.new(2026, 9, 1))

    assert_equal "Aug 15 – Sep 01", Performance::SeriesPresenter.new(series).date_range_label
  end

  test "includes the year when the range crosses years" do
    series = series_with(Date.new(2025, 8, 15), Date.new(2026, 9, 1))

    assert_equal "Aug 15, 2025 – Sep 01, 2026", Performance::SeriesPresenter.new(series).date_range_label
  end

  private

  def series_with(from, to)
    Performance::Series::Result.new(from:, to:, observations: [], status: :empty)
  end
end
