require "test_helper"

class Performance::SeriesTest < ActiveSupport::TestCase
  setup do
    @from = Date.new(2026, 8, 26)
    @to = Date.new(2026, 8, 28)
  end

  test "builds daily observations with net invested capital" do
    series = Performance::Series.for(from: @from, to: @to, portfolio: portfolio_with(
      @from => valuation(@from, "100"),
      @from + 1 => valuation(@from + 1, "110"),
      @to => valuation(@to, "105")
    ))

    assert_predicate series, :available?
    assert_equal [ @from, @from + 1, @to ], series.observations.map(&:date)
    assert_equal BigDecimal("10"), series.observations[1].gain_loss_amount
    assert_equal BigDecimal("0"), series.observations[1].invested_amount
  end

  test "preserves missing history instead of treating it as zero" do
    series = Performance::Series.for(from: @from, to: @to, portfolio: portfolio_with(
      @from => valuation(@from, "100"),
      @from + 1 => valuation(@from + 1, nil, status: :missing),
      @to => valuation(@to, "105")
    ))

    assert_predicate series, :missing?
    assert_equal [ @from + 1 ], series.missing_dates
  end

  test "uses net cash flow for the invested line" do
    result = Performance::Series.for(from: @from, to: @from, portfolio: portfolio_with(
      @from => valuation(@from, "100", net_cash_flow: "40")
    ))

    assert_equal BigDecimal("40"), result.observations.first.invested_amount
    assert_equal Money.from_amount(40, "BRL"), result.observations.first.invested_value
  end

  test "returns an empty series when the range contains no weekdays" do
    saturday = Date.new(2026, 8, 29)
    series = Performance::Series.for(from: saturday, to: saturday + 1, portfolio: portfolio_with({}))

    assert_predicate series, :empty?
    assert_empty series.observations
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

  def valuation(date, amount, status: :available, net_cash_flow: "0")
    value = amount && BigDecimal(amount)
    money = value && Money.from_amount(value, "BRL")
    Performance::Portfolio::Result.new(
      valuation_date: date, market_value_amount: value, market_value: money,
      realized_gain_amount: value, realized_gain: money,
      unrealized_gain_amount: BigDecimal("0"), unrealized_gain: Money.new(0, "BRL"),
      net_cash_flow_amount: BigDecimal(net_cash_flow), net_cash_flow: Money.from_amount(BigDecimal(net_cash_flow), "BRL"),
      status:, position_results: [ position_result(net_cash_flow) ], cash_flows: []
    )
  end

  def position_result(net_cash_flow)
    Performance::Portfolio::PositionResult.new(
      instrument: nil, quantity: BigDecimal("1"), reporting_cost_basis_amount: BigDecimal("0"),
      market_value_amount: BigDecimal("0"), realized_gain_amount: BigDecimal("0"),
      unrealized_gain_amount: BigDecimal("0"), net_cash_flow_amount: BigDecimal(net_cash_flow),
      invested_amount: BigDecimal("999"), status: :available, daily_closing_price: nil,
      exchange_rate_lookup: nil, cash_flows: []
    )
  end
end
