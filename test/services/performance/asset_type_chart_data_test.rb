require "test_helper"

class Performance::AssetTypeChartDataTest < ActiveSupport::TestCase
  setup do
    @user = users(:owner)
    Trade.where(user: @user).delete_all
    InstrumentPerformanceObservation.where(user: @user).delete_all
    @from = Date.new(2026, 9, 1)
    @to = Date.new(2026, 9, 3)
  end

  test "calculates an independent Modified Dietz return for every asset type" do
    stock = create_instrument(ticker: "ATST", asset_type: :stock)
    bond = create_instrument(ticker: "ATBD", asset_type: :bond)
    create_trade(stock, unit_price: "100")
    create_trade(bond, unit_price: "200")
    create_observation(stock, @from, market_value: "100", cash_flow: 100)
    create_observation(stock, @to, market_value: "130", cash_flow: 100, flow_date: @from)
    create_observation(bond, @from, market_value: "200", cash_flow: 200)
    create_observation(bond, @to, market_value: "210", cash_flow: 200, flow_date: @from)

    data = Performance::AssetTypeChartData.for(
      series: series, user: @user, reporting_currency: "BRL"
    )

    assert_equal [ "Bond", "Stock" ], data.map { |item| item.fetch(:label) }
    assert_equal [ BigDecimal("0"), nil, BigDecimal("0.05") ], data.fetch(0).fetch(:values)
    assert_equal [ BigDecimal("0"), nil, BigDecimal("0.3") ], data.fetch(1).fetch(:values)
  end

  test "starts a type when its first complete observation becomes available" do
    instrument = create_instrument(ticker: "ATLATE", asset_type: :etf)
    create_trade(instrument, date: @from + 1, unit_price: "100")
    create_observation(instrument, @from + 1, market_value: "100", cash_flow: 100, flow_date: @from + 1)
    create_observation(instrument, @to, market_value: "110", cash_flow: 100, flow_date: @from + 1)

    values = Performance::AssetTypeChartData.for(
      series: series, user: @user, reporting_currency: "BRL"
    ).sole.fetch(:values)

    assert_nil values.fetch(0)
    assert_equal BigDecimal("0"), values.fetch(1)
    assert_equal BigDecimal("0.1"), values.fetch(2)
  end

  test "leaves a type return unavailable after a missing observation" do
    instrument = create_instrument(ticker: "ATMISS", asset_type: :fund)
    create_trade(instrument, unit_price: "100")
    create_observation(instrument, @from, market_value: "100", cash_flow: 100)
    create_missing_observation(instrument, @to)

    values = Performance::AssetTypeChartData.for(
      series: series, user: @user, reporting_currency: "BRL"
    ).sole.fetch(:values)

    assert_equal BigDecimal("0"), values.fetch(0)
    assert_nil values.fetch(1)
  end

  test "omits a type without a complete opening observation" do
    instrument = create_instrument(ticker: "ATEMPTY", asset_type: :other)
    create_trade(instrument, unit_price: "100")
    create_missing_observation(instrument, @from)

    data = Performance::AssetTypeChartData.for(
      series: series, user: @user, reporting_currency: "BRL"
    )

    assert_empty data
  end

  test "returns no data for an empty series" do
    empty = Performance::Series::Result.new(
      from: @from, to: @to, observations: [], status: :empty, refresh_status: nil
    )

    assert_empty Performance::AssetTypeChartData.for(series: empty, user: @user, reporting_currency: "BRL")
  end

  test "leaves returns unavailable for unusable aggregate inputs" do
    service = Performance::AssetTypeChartData.new(series:, user: @user, reporting_currency: "BRL")
    opening = Performance::AssetTypeChartData::Aggregate.new(BigDecimal("100"), 0, 0, :available)
    missing = Performance::AssetTypeChartData::Aggregate.new(nil, nil, nil, :missing)
    zero = Performance::AssetTypeChartData::Aggregate.new(BigDecimal("0"), 0, 0, :available)

    assert_nil service.send(:return_ratio_for, date: @to, aggregate: nil, opening_date: @from, opening:)
    assert_nil service.send(:return_ratio_for, date: @to, aggregate: missing, opening_date: @from, opening:)
    assert_nil service.send(:return_ratio_for, date: @from - 1.day, aggregate: opening, opening_date: @from, opening:)
    assert_nil service.send(:return_ratio_for, date: @to, aggregate: zero, opening_date: @from, opening: zero)
  end

  private

  def series
    observations = (@from..@to).map do |date|
      Performance::Series::Observation.new(
        date:, market_value_amount: nil, market_value: nil, invested_amount: nil,
        invested_value: nil, gain_loss_amount: nil, gain_loss: nil, return_ratio: nil,
        gain_on_cost_ratio: nil, status: :available
      )
    end
    Performance::Series::Result.new(
      from: @from, to: @to, observations:, status: :available, refresh_status: nil
    )
  end

  def create_instrument(ticker:, asset_type:)
    Instrument.create!(ticker:, exchange: "BVMF", name: "#{ticker} instrument", currency: "BRL", asset_type:)
  end

  def create_trade(instrument, date: @from, unit_price:)
    @user.trades.create!(
      instrument:, traded_on: date, side: :buy, quantity: 1, unit_price:, fees_cents: 0, currency: "BRL"
    )
  end

  def create_observation(instrument, date, market_value:, cash_flow:, flow_date: @from)
    InstrumentPerformanceObservation.create!(
      user: @user, instrument:, observed_on: date, reporting_currency: "BRL",
      market_value_amount: market_value, cost_basis_amount: cash_flow,
      realized_gain_amount: "0", unrealized_gain_amount: "0", net_cash_flow_amount: cash_flow,
      investment_income_amount: "0", invested_amount: cash_flow,
      cash_flow_total: Rational(cash_flow), dated_cash_flow_total: Rational(cash_flow) * flow_date.jd,
      status: :available, source_generation: 0, generated_at: Time.current
    )
  end

  def create_missing_observation(instrument, date)
    InstrumentPerformanceObservation.create!(
      user: @user, instrument:, observed_on: date, reporting_currency: "BRL",
      cash_flow_total: 0, dated_cash_flow_total: 0, status: :missing,
      source_generation: 0, generated_at: Time.current
    )
  end
end
