require "test_helper"

class InstrumentPerformance::ObservationStoreTest < ActiveSupport::TestCase
  setup do
    @user = users(:owner)
    @instrument = instruments(:voo_arcx)
    @store = InstrumentPerformance::ObservationStore.new(
      user: @user,
      instrument: @instrument,
      reporting_currency: "USD"
    )
    @date = Date.new(2026, 9, 1)
  end

  test "writes and replaces every exact instrument amount for one target date" do
    @store.write(valuation(market_value: "100"), generated_at: Time.zone.parse("2026-09-01 10:00"))
    @store.write(valuation(market_value: "101"), generated_at: Time.zone.parse("2026-09-01 11:00"))

    record = @store.read(from: @date, to: @date).fetch(@date)
    assert_equal BigDecimal("101"), record.market_value_amount
    assert_equal BigDecimal("80.12345678901234567890123456789"), record.cost_basis_amount
    assert_equal BigDecimal("7.1"), record.realized_gain_amount
    assert_equal BigDecimal("13.77654321098765432109876543211"), record.unrealized_gain_amount
    assert_equal BigDecimal("73.02345678901234567890123456789"), record.net_cash_flow_amount
    assert_equal BigDecimal("4.5"), record.investment_income_amount
    assert_equal BigDecimal("90.22222222222222222222222222222"), record.invested_amount
    assert_equal Rational(7, 3), record.cash_flow_total
    assert_equal Rational(7, 3) * @date.jd, record.dated_cash_flow_total
    assert_equal Time.zone.parse("2026-09-01 11:00"), record.generated_at
    assert_nil record.stale_at
    assert_equal 1, InstrumentPerformanceObservation.where(user: @user, instrument: @instrument).count
  end

  test "stores closed positions as available exact outcomes" do
    closed = valuation(
      market_value: "0",
      cost_basis: "0",
      realized_gain: "25.5",
      unrealized_gain: "0",
      net_cash_flow: "-25.5",
      position_status: :closed
    )

    @store.write(closed)

    record = @store.read(from: @date, to: @date).fetch(@date)
    assert_predicate record, :available?
    assert_equal BigDecimal("25.5"), record.realized_gain_amount
    assert_equal BigDecimal("0"), record.market_value_amount
  end

  test "stores empty history as zero and missing source history as null" do
    empty = Valuation.new(valuation_date: @date, status: :empty, position_results: [], cash_flows: [])
    @store.write(empty)
    empty_record = @store.read(from: @date, to: @date).fetch(@date)

    assert_predicate empty_record, :empty?
    InstrumentPerformanceObservation::DECIMAL_ATTRIBUTES.each do |attribute|
      assert_equal BigDecimal("0"), empty_record.public_send(attribute)
    end

    missing = Valuation.new(valuation_date: @date, status: :missing, position_results: [], cash_flows: [])
    @store.write(missing)
    missing_record = @store.read(from: @date, to: @date).fetch(@date)

    assert_predicate missing_record, :missing?
    InstrumentPerformanceObservation::DECIMAL_ATTRIBUTES.each do |attribute|
      assert_nil missing_record.public_send(attribute)
    end
  end

  test "marks and deletes only the selected instrument and currency" do
    @store.write(valuation)
    reporting_store = InstrumentPerformance::ObservationStore.new(
      user: @user, instrument: @instrument, reporting_currency: "BRL"
    )
    reporting_store.write(valuation)
    other_store = InstrumentPerformance::ObservationStore.new(
      user: @user, instrument: instruments(:petr4_bvmf), reporting_currency: "BRL"
    )
    other_store.write(valuation(instrument: instruments(:petr4_bvmf)))

    travel_to(Time.zone.parse("2026-09-03 09:00")) { @store.stale_from(@date) }

    assert_equal Time.zone.parse("2026-09-03 09:00"), @store.read(from: @date, to: @date).fetch(@date).stale_at
    assert_nil reporting_store.read(from: @date, to: @date).fetch(@date).stale_at
    assert_nil other_store.read(from: @date, to: @date).fetch(@date).stale_at

    assert_equal 1, @store.delete_all
    assert_equal 1, reporting_store.read(from: @date, to: @date).size
    assert_equal 1, other_store.read(from: @date, to: @date).size
  end

  test "rejects a valuation for another instrument" do
    assert_raises(ArgumentError) do
      @store.write(valuation(instrument: instruments(:petr4_bvmf)))
    end
  end

  test "serializes absent analytical amounts as absent" do
    assert_nil @store.send(:serialize_decimal, nil)
  end

  private

  PositionResult = Data.define(
    :instrument, :reporting_cost_basis_amount, :market_value_amount,
    :realized_gain_amount, :unrealized_gain_amount, :net_cash_flow_amount,
    :investment_income_amount, :invested_amount, :status
  )
  Valuation = Data.define(:valuation_date, :status, :position_results, :cash_flows)

  def valuation(instrument: @instrument, market_value: "100", cost_basis: "80.12345678901234567890123456789",
    realized_gain: "7.1", unrealized_gain: "13.77654321098765432109876543211",
    net_cash_flow: "73.02345678901234567890123456789",
    investment_income: "4.5", invested: "90.22222222222222222222222222222", position_status: :available)
    result = PositionResult.new(
      instrument:,
      reporting_cost_basis_amount: BigDecimal(cost_basis),
      market_value_amount: BigDecimal(market_value),
      realized_gain_amount: BigDecimal(realized_gain),
      unrealized_gain_amount: BigDecimal(unrealized_gain),
      net_cash_flow_amount: BigDecimal(net_cash_flow),
      investment_income_amount: BigDecimal(investment_income),
      invested_amount: BigDecimal(invested),
      status: position_status
    )
    flow = Performance::Portfolio::CashFlow.new(
      occurred_on: @date, amount: Rational(7, 3), source: :trade
    )
    Valuation.new(valuation_date: @date, status: :available, position_results: [ result ], cash_flows: [ flow ])
  end
end
