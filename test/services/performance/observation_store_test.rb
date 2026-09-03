require "test_helper"

class Performance::ObservationStoreTest < ActiveSupport::TestCase
  setup do
    @user = users(:owner)
    @store = Performance::ObservationStore.new(user: @user, reporting_currency: "BRL")
  end

  test "writes and replaces one exact observation per date" do
    date = Date.new(2026, 9, 1)
    @store.write(valuation(date:, market_value: "100"), generated_at: Time.zone.parse("2026-09-01 10:00"))
    @store.write(valuation(date:, market_value: "101"), generated_at: Time.zone.parse("2026-09-01 11:00"))

    record = @store.read(from: date, to: date).fetch(date)
    assert_equal BigDecimal("101"), record.market_value_amount
    assert_equal Time.zone.parse("2026-09-01 11:00"), record.generated_at
    assert_nil record.stale_at
    assert_equal Rational(80), record.cash_flow_total
    assert_equal Rational(80 * date.jd), record.dated_cash_flow_total
    assert_equal 1, PortfolioPerformanceObservation.where(user: @user).count
  end

  test "round trips exact fractional dated flows without a decimal boundary" do
    date = Date.new(2026, 9, 1)
    first_amount = Rational(1, 3)
    second_amount = Rational(-1, 7)
    flows = [
      Performance::Portfolio::CashFlow.new(traded_on: date - 1, amount: first_amount),
      Performance::Portfolio::CashFlow.new(traded_on: date, amount: second_amount)
    ]
    @store.write(valuation(date:).with(cash_flows: flows))

    record = @store.read(from: date, to: date).fetch(date)

    assert_equal Rational(4, 21), record.cash_flow_total
    assert_equal first_amount * (date - 1).jd + second_amount * date.jd, record.dated_cash_flow_total
  end

  test "marks only later observations in the same reporting scope stale" do
    dates = [ Date.new(2026, 8, 31), Date.new(2026, 9, 1) ]
    dates.each { |date| @store.write(valuation(date:), generated_at: Time.current) }
    other_currency = Performance::ObservationStore.new(user: @user, reporting_currency: "USD")
    other_currency.write(valuation(date: dates.last), generated_at: Time.current)

    travel_to(Time.zone.parse("2026-09-03 09:00")) { @store.stale_from(dates.last) }

    assert_nil @store.read(from: dates.first, to: dates.first).fetch(dates.first).stale_at
    assert_equal Time.zone.parse("2026-09-03 09:00"), @store.read(from: dates.last, to: dates.last).fetch(dates.last).stale_at
    assert_nil other_currency.read(from: dates.last, to: dates.last).fetch(dates.last).stale_at
  end

  test "preserves nil amounts for missing source history" do
    date = Date.new(2026, 9, 1)
    missing = Valuation.new(
      valuation_date: date,
      market_value_amount: nil,
      net_cash_flow_amount: nil,
      cash_flows: [],
      status: :missing
    )

    @store.write(missing, generated_at: Time.current)

    record = @store.read(from: date, to: date).fetch(date)
    assert_nil record.market_value_amount
    assert_nil record.net_cash_flow_amount
  end

  private

  Valuation = Data.define(:valuation_date, :market_value_amount, :net_cash_flow_amount, :status, :cash_flows)

  def valuation(date:, market_value: "100")
    Valuation.new(
      valuation_date: date,
      market_value_amount: BigDecimal(market_value),
      net_cash_flow_amount: BigDecimal("80"),
      cash_flows: [ Performance::Portfolio::CashFlow.new(traded_on: date, amount: Rational(80)) ],
      status: :available
    )
  end
end
