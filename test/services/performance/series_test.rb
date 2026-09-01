require "test_helper"

class Performance::SeriesTest < ActiveSupport::TestCase
  setup do
    @from = Date.new(2026, 8, 26)
    @to = Date.new(2026, 8, 28)
  end

  test "builds daily observations and normalized chart points" do
    series = Performance::Series.for(from: @from, to: @to, portfolio: portfolio_with(
      @from => valuation(@from, "100"),
      @from + 1 => valuation(@from + 1, "110"),
      @to => valuation(@to, "105")
    ))

    assert_predicate series, :available?
    assert_equal [ @from, @from + 1, @to ], series.observations.map(&:date)
    assert_equal [ [ 0.0, 100.0 ], [ 50.0, 0.0 ], [ 100.0, 50.0 ] ], series.chart_points
    assert_equal BigDecimal("10"), series.observations[1].gain_loss_amount
  end

  test "preserves missing history instead of treating it as zero" do
    series = Performance::Series.for(from: @from, to: @to, portfolio: portfolio_with(
      @from => valuation(@from, "100"),
      @from + 1 => valuation(@from + 1, nil, status: :missing),
      @to => valuation(@to, "105")
    ))

    assert_predicate series, :missing?
    assert_equal [ @from + 1 ], series.missing_dates
    assert_equal 2, series.chart_points.length
  end

  test "returns an empty series when the range contains no weekdays" do
    saturday = Date.new(2026, 8, 29)
    series = Performance::Series.for(from: saturday, to: saturday + 1, portfolio: portfolio_with({}))

    assert_predicate series, :empty?
    assert_empty series.observations
    assert_empty series.chart_points
  end

  test "rejects invalid or future ranges" do
    portfolio = portfolio_with({})

    assert_raises(ArgumentError) { Performance::Series.for(from: @to, to: @from, portfolio:) }
    assert_raises(ArgumentError) { Performance::Series.for(from: @from, to: Date.current + 1, portfolio:) }
  end

  private

  StubPortfolio = Data.define(:valuations) do
    def for(valuation_date:)
      valuations.fetch(valuation_date)
    end
  end

  def portfolio_with(valuations)
    StubPortfolio.new(valuations:)
  end

  def valuation(date, amount, status: :available)
    value = amount && BigDecimal(amount)
    money = value && Money.from_amount(value, "BRL")
    Performance::Portfolio::Result.new(
      valuation_date: date, market_value_amount: value, market_value: money,
      realized_gain_amount: value, realized_gain: money,
      unrealized_gain_amount: BigDecimal("0"), unrealized_gain: Money.new(0, "BRL"),
      net_cash_flow_amount: BigDecimal("0"), net_cash_flow: Money.new(0, "BRL"),
      status:, position_results: [], cash_flows: []
    )
  end
end
