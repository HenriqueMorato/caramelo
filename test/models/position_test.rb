require "test_helper"

class PositionTest < ActiveSupport::TestCase
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
    trade = create_trade(instrument:, side: :sell, quantity: 1)

    error = assert_raises(Position::InvalidLongOnlyData) { Position.for(instrument:) }

    assert_equal trade, error.trade
  end

  test "keeps basis and exact average cost in the instrument currency" do
    instrument = create_instrument(ticker: "ACPT", exchange: "XNAS", currency: "USD")
    create_trade(instrument:, quantity: 3, unit_price: "10", fees_cents: 1)

    position = Position.for(instrument:)

    assert_equal "USD", position.cost_basis.currency.iso_code
    assert_equal Money.from_amount(BigDecimal("30.01"), "USD"), position.cost_basis
    assert_equal BigDecimal("30.01") / 3, position.average_unit_cost
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
end
