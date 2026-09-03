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

  test "formats chart values and signed returns without replacing missing data" do
    date = Date.new(2026, 8, 15)
    observations = [ BigDecimal("0.1"), BigDecimal("-0.2"), BigDecimal("0"), nil ].map do |ratio|
      money = Money.from_amount(100, "BRL") if ratio
      Performance::Series::Observation.new(
        date:, market_value_amount: money&.to_d, market_value: money,
        invested_amount: money&.to_d, invested_value: money,
        gain_loss_amount: nil, gain_loss: nil, return_ratio: ratio,
        status: ratio ? :available : :missing
      )
    end
    series = series_with(date, date).with(observations:)

    data = Performance::SeriesPresenter.new(series).chart_data(benchmarks: [], currency: "BRL")

    assert_equal [ 100.0, 100.0, 100.0, nil ], data[:values]
    assert_equal data[:values], data[:invested_values]
    assert_equal [ "↑ +10.00%", "↓ -20.00%", "→ 0.00%", nil ], data[:formatted_performances]
    assert_equal "Portfolio value", data[:portfolio_value_label]
    assert_equal "BRL", data[:currency]
    assert_equal [ "Aug 15" ] * 4, data[:labels]
  end

  private

  def series_with(from, to)
    Performance::Series::Result.new(from:, to:, observations: [], status: :empty, refresh_status: nil)
  end
end
