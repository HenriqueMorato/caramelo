require "test_helper"

class PositionTest < ActiveSupport::TestCase
  test "builds an alphabetical overview for instruments traded by the configured owner" do
    Trade.where(user: users(:owner)).delete_all
    later_instrument = create_instrument(ticker: "ZZZZ", exchange: "XNAS", currency: "USD")
    earlier_instrument = create_instrument(ticker: "AAAA", exchange: "BVMF", currency: "BRL")
    create_trade(instrument: later_instrument, quantity: 2)
    create_trade(instrument: earlier_instrument, quantity: 3)
    create_trade(instrument: create_instrument(ticker: "OTHR"), user: users(:one), quantity: 100)

    results = Position.overview

    assert_equal [ earlier_instrument, later_instrument ], results.map(&:instrument)
    assert_equal [ BigDecimal("3"), BigDecimal("2") ], results.map { |result| result.position.quantity }
    assert results.none?(&:invalid?)
  end

  test "loads overview trades and instruments in a bounded number of queries" do
    create_trade(instrument: create_instrument(ticker: "MORE"))

    assert_queries_count(3) { Position.overview }
  end

  test "keeps invalid instruments visible in the overview without hiding valid positions" do
    valid_instrument = create_instrument(ticker: "GOOD")
    invalid_instrument = create_instrument(ticker: "BAD1")
    create_trade(instrument: valid_instrument)
    invalid_trade = create_trade(instrument: invalid_instrument, side: :sell)

    results = Position.overview
    valid_result = results.find { |result| result.instrument == valid_instrument }
    invalid_result = results.find { |result| result.instrument == invalid_instrument }

    assert_equal BigDecimal("1"), valid_result.position.quantity
    assert_not_predicate valid_result, :invalid?
    assert_predicate invalid_result, :invalid?
    assert_equal invalid_trade, invalid_result.error.trade
    assert_nil invalid_result.position
  end

  test "calculates one instrument for the configured owner in trade chronology" do
    instrument = create_instrument
    sell = create_trade(instrument:, side: :sell, traded_on: Date.new(2026, 1, 2), quantity: 1)
    buy = create_trade(instrument:, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 2)
    create_trade(instrument:, user: users(:one), side: :buy, traded_on: Date.new(2025, 12, 31), quantity: 100)
    create_trade(instrument: create_instrument(ticker: "OTHR"), quantity: 100)

    position = Position.for(instrument:)

    assert_equal instrument, position.instrument
    assert_equal BigDecimal("1"), position.quantity
    assert_equal Money.from_amount(10, "BRL"), position.cost_basis
    assert_equal BigDecimal("10"), position.average_unit_cost
    assert_equal buy.traded_on, position.first_trade_date
    assert_equal sell.traded_on, position.last_trade_date
    assert_predicate position, :open?
    assert_not_predicate position, :closed?
  end

  test "uses weighted-average cost and includes buy fees" do
    instrument = create_instrument
    create_trade(instrument:, quantity: 2, unit_price: "10", fees_cents: 100)
    create_trade(instrument:, quantity: 3, unit_price: "20", fees_cents: 200)

    position = Position.for(instrument:)

    assert_equal BigDecimal("5"), position.quantity
    assert_equal Money.from_amount(83, "BRL"), position.cost_basis
    assert_equal BigDecimal("16.6"), position.average_unit_cost
  end

  test "keeps a precise average for a fractional quantity and three-decimal price" do
    instrument = create_instrument
    create_trade(instrument:, quantity: "5.12345678", unit_price: "1.234")

    position = Position.for(instrument:)

    assert_equal BigDecimal("5.12345678"), position.quantity
    assert_equal Money.from_amount(BigDecimal("6.32"), "BRL"), position.cost_basis
    assert_equal BigDecimal("1.234"), position.average_unit_cost
  end

  test "capitalizes fees without rounding a fractional ETF basis before averaging" do
    instrument = create_instrument
    quantity = BigDecimal("5.12345678")
    unit_price = BigDecimal("1.234")
    exact_basis = quantity * unit_price + BigDecimal("0.37")
    create_trade(instrument:, quantity:, unit_price:, fees_cents: 37)

    position = Position.for(instrument:)
    expected_average = BigDecimal(exact_basis.to_r / quantity.to_r, 48)

    assert_equal exact_basis, position.analytical_cost_basis_amount
    assert_equal Money.from_amount(exact_basis, "BRL"), position.cost_basis
    assert_equal expected_average, position.average_unit_cost
  end

  test "calculates a one-satoshi Bitcoin position with a precise price and fee" do
    instrument = create_instrument(ticker: "BTC", exchange: "XCRY", currency: "USD")
    quantity = BigDecimal("0.00000001")
    unit_price = BigDecimal("98765.43218765")
    exact_basis = quantity * unit_price + BigDecimal("0.01")
    create_trade(instrument:, quantity:, unit_price:, fees_cents: 1)

    position = Position.for(instrument:)

    assert_equal quantity, position.quantity
    assert_equal exact_basis, position.analytical_cost_basis_amount
    assert_equal Money.from_amount(exact_basis, "USD"), position.cost_basis
    assert_equal exact_basis / quantity, position.average_unit_cost
  end

  test "a partial sale reduces basis at the existing average cost" do
    instrument = create_instrument
    create_trade(instrument:, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 2, unit_price: "10", fees_cents: 100)
    create_trade(instrument:, side: :buy, traded_on: Date.new(2026, 1, 2), quantity: 3, unit_price: "20", fees_cents: 200)
    create_trade(instrument:, side: :sell, traded_on: Date.new(2026, 1, 3), quantity: 2, unit_price: "100", fees_cents: 500)

    position = Position.for(instrument:)

    assert_equal BigDecimal("3"), position.quantity
    assert_equal Money.from_amount(BigDecimal("49.80"), "BRL"), position.cost_basis
    assert_equal BigDecimal("16.6"), position.average_unit_cost
  end

  test "calculates realized gain from exact allocated basis and net sale proceeds" do
    instrument = create_instrument
    create_trade(instrument:, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 2, unit_price: "10", fees_cents: 100)
    create_trade(instrument:, side: :sell, traded_on: Date.new(2026, 1, 2), quantity: 1, unit_price: "15", fees_cents: 200)

    position = Position.for(instrument:)

    assert_equal BigDecimal("10.5"), position.analytical_cost_basis_amount
    assert_equal BigDecimal("2.5"), position.analytical_realized_gain_amount
    assert_equal Money.from_amount(BigDecimal("2.5"), "BRL"), position.realized_gain
  end

  test "builds a position from trades on or before an as-of date" do
    instrument = create_instrument
    create_trade(instrument:, traded_on: Date.new(2026, 1, 1), quantity: 2, unit_price: "10")
    create_trade(instrument:, side: :sell, traded_on: Date.new(2026, 1, 2), quantity: 1, unit_price: "15")

    position = Position.for(instrument:, as_of: Date.new(2026, 1, 1))

    assert_equal BigDecimal("2"), position.quantity
    assert_equal BigDecimal("20"), position.analytical_cost_basis_amount
    assert_equal BigDecimal("0"), position.analytical_realized_gain_amount
  end

  test "a buy after a partial sale blends with the remaining average" do
    instrument = create_instrument
    create_trade(instrument:, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 10, unit_price: "10")
    create_trade(instrument:, side: :sell, traded_on: Date.new(2026, 1, 2), quantity: 4, unit_price: "1000", fees_cents: 200)
    create_trade(instrument:, side: :buy, traded_on: Date.new(2026, 1, 3), quantity: 2, unit_price: "100")

    position = Position.for(instrument:)

    assert_equal BigDecimal("8"), position.quantity
    assert_equal BigDecimal("260"), position.analytical_cost_basis_amount
    assert_equal BigDecimal("32.5"), position.average_unit_cost
  end

  test "a fully sold position has zero quantity and basis" do
    instrument = create_instrument
    create_trade(instrument:, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: "1.25", unit_price: "8")
    create_trade(instrument:, side: :sell, traded_on: Date.new(2026, 1, 2), quantity: "1.25", unit_price: "12")

    position = Position.for(instrument:)

    assert_equal BigDecimal("0"), position.quantity
    assert_equal Money.new(0, "BRL"), position.cost_basis
    assert_equal BigDecimal("0"), position.average_unit_cost
    assert_predicate position, :closed?
    assert_not_predicate position, :open?
  end

  test "a buy after full closure starts a fresh average" do
    instrument = create_instrument
    create_trade(instrument:, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: 3, unit_price: "40", fees_cents: 30)
    create_trade(instrument:, side: :sell, traded_on: Date.new(2026, 1, 2), quantity: 3, unit_price: "5", fees_cents: 20)
    create_trade(instrument:, side: :buy, traded_on: Date.new(2026, 1, 3), quantity: 2, unit_price: "100", fees_cents: 10)

    position = Position.for(instrument:)

    assert_equal BigDecimal("2"), position.quantity
    assert_equal BigDecimal("200.1"), position.analytical_cost_basis_amount
    assert_equal BigDecimal("100.05"), position.average_unit_cost
  end

  test "an instrument without owner trades has a closed zero position" do
    position = Position.for(instrument: create_instrument)

    assert_equal BigDecimal("0"), position.quantity
    assert_equal Money.new(0, "BRL"), position.cost_basis
    assert_nil position.first_trade_date
    assert_nil position.last_trade_date
    assert_predicate position, :closed?
  end

  test "raises when chronological trades imply a short position" do
    instrument = create_instrument
    create_trade(instrument:, side: :buy, traded_on: Date.new(2026, 1, 1), quantity: "1.00000000")
    trade = create_trade(
      instrument:,
      side: :sell,
      traded_on: Date.new(2026, 1, 2),
      quantity: "1.00000001"
    )

    error = assert_raises(Position::InvalidLongOnlyData) { Position.for(instrument:) }

    assert_equal trade, error.trade
  end

  test "uses creation order to break ties between trades on the same date" do
    trade_date = Date.new(2026, 1, 1)
    buy_first = create_instrument(ticker: "SAME")
    create_trade(instrument: buy_first, side: :buy, traded_on: trade_date - 1, unit_price: "10")
    create_trade(instrument: buy_first, side: :buy, traded_on: trade_date, unit_price: "30")
    create_trade(instrument: buy_first, side: :sell, traded_on: trade_date, unit_price: "100")

    buy_first_position = Position.for(instrument: buy_first)
    assert_equal BigDecimal("1"), buy_first_position.quantity
    assert_equal BigDecimal("20"), buy_first_position.average_unit_cost

    sell_first = create_instrument(ticker: "REVS")
    create_trade(instrument: sell_first, side: :buy, traded_on: trade_date - 1, unit_price: "10")
    create_trade(instrument: sell_first, side: :sell, traded_on: trade_date, unit_price: "100")
    create_trade(instrument: sell_first, side: :buy, traded_on: trade_date, unit_price: "30")

    sell_first_position = Position.for(instrument: sell_first)
    assert_equal BigDecimal("1"), sell_first_position.quantity
    assert_equal BigDecimal("30"), sell_first_position.average_unit_cost
  end

  test "rounds exact analytical basis at half-cent currency boundaries" do
    {
      "0.00490000" => 0,
      "0.00499999" => 0,
      "0.00500000" => 1,
      "0.00500001" => 1
    }.each_with_index do |(unit_price, expected_cents), index|
      instrument = create_instrument(ticker: "RND#{index}", exchange: "XNAS", currency: "USD")
      create_trade(instrument:, unit_price:)

      position = Position.for(instrument:)

      assert_equal BigDecimal(unit_price), position.average_unit_cost
      assert_equal Money.from_cents(expected_cents, "USD"), position.cost_basis
    end
  end

  test "distinguishes exact sub-cent basis from individually rounded trade totals" do
    instrument = create_instrument(ticker: "SUBC", exchange: "XNAS", currency: "USD")
    trades = 2.times.map { create_trade(instrument:, unit_price: "0.00490000") }
    position = Position.for(instrument:)

    assert_equal BigDecimal("0.0098"), position.analytical_cost_basis_amount
    assert_equal Money.from_cents(1, "USD"), position.cost_basis
    assert_equal Money.from_cents(0, "USD"), sum_totals(trades)
  end

  test "distinguishes exact half-cent basis from individually rounded trade totals" do
    instrument = create_instrument(ticker: "HALF", exchange: "XNAS", currency: "USD")
    trades = 2.times.map { create_trade(instrument:, unit_price: "0.00500000") }
    position = Position.for(instrument:)

    assert_equal BigDecimal("0.01"), position.analytical_cost_basis_amount
    assert_equal Money.from_cents(1, "USD"), position.cost_basis
    assert_equal Money.from_cents(2, "USD"), sum_totals(trades)
  end

  test "repeated fractional sales do not materially drift from the weighted average" do
    instrument = create_instrument(ticker: "DRFT", exchange: "XNAS", currency: "USD")
    bought_quantity = BigDecimal("3.33333333")
    unit_price = BigDecimal("12345.67891234")
    exact_basis = bought_quantity * unit_price + BigDecimal("0.17")
    expected_average = exact_basis / bought_quantity
    sold_quantity = BigDecimal("0.11111111")
    create_trade(instrument:, quantity: bought_quantity, unit_price:, fees_cents: 17)

    12.times do |index|
      create_trade(
        instrument:,
        side: :sell,
        traded_on: Date.new(2026, 1, 2) + index,
        quantity: sold_quantity,
        unit_price: BigDecimal("100") + index,
        fees_cents: index + 1
      )
    end

    position = Position.for(instrument:)
    expected_quantity = bought_quantity - sold_quantity * 12
    expected_basis = expected_average * expected_quantity

    assert_equal expected_quantity, position.quantity
    assert_in_delta expected_basis, position.analytical_cost_basis_amount, BigDecimal("1e-30")
    assert_in_delta expected_average, position.average_unit_cost, BigDecimal("1e-30")
    assert_equal Money.from_amount(expected_basis, "USD"), position.cost_basis
  end

  test "keeps basis and exact average cost in the instrument currency" do
    instrument = create_instrument(ticker: "ACPT", exchange: "XNAS", currency: "USD")
    create_trade(instrument:, quantity: 3, unit_price: "10", fees_cents: 1)

    position = Position.for(instrument:)

    assert_equal "USD", position.cost_basis.currency.iso_code
    assert_equal Money.from_amount(BigDecimal("30.01"), "USD"), position.cost_basis
    assert_equal BigDecimal(BigDecimal("30.01").to_r / 3, 48), position.average_unit_cost
  end

  test "reflects edited and deleted trades without persisting a position" do
    instrument = create_instrument
    trade = create_trade(instrument:, quantity: 2)

    assert_equal BigDecimal("2"), Position.for(instrument:).quantity

    trade.update!(quantity: 3)
    assert_equal BigDecimal("3"), Position.for(instrument:).quantity

    trade.destroy!
    assert_equal BigDecimal("0"), Position.for(instrument:).quantity
  end

  private

  def create_instrument(ticker: "POSI", exchange: "BVMF", currency: "BRL")
    Instrument.create!(ticker:, exchange:, name: "Position Test", currency:)
  end

  def create_trade(instrument:, user: users(:owner), side: :buy, traded_on: Date.new(2026, 1, 1),
    quantity: 1, unit_price: "10", fees_cents: 0)
    user.trades.create!(
      instrument:,
      side:,
      traded_on:,
      quantity:,
      unit_price:,
      fees_cents:,
      currency: instrument.currency
    )
  end

  def sum_totals(trades)
    trades.sum(Money.new(0, trades.first.currency), &:total)
  end
end
