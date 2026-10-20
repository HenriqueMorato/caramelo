require "test_helper"

class Position::AllocationTest < ActiveSupport::TestCase
  PositionState = Struct.new(:open?) do
    def closed? = !open?
  end
  ValuationState = Struct.new(:market_value) do
    def available? = market_value.present?
  end
  Presenter = Struct.new(:invalid?, :position, :valuation, :instrument)

  test "groups available open values by type and position" do
    stock = Instrument.new(id: 1, ticker: "AAA", exchange: "BVMF", asset_type: :stock)
    bond = Instrument.new(id: 2, ticker: "BBB", exchange: "BVMF", asset_type: :bond)
    positions = [
      presenter(stock, "200"),
      presenter(bond, "100")
    ]

    result = Position::Allocation.for(positions:, reporting_currency: "BRL")

    assert_predicate result, :available?
    assert_equal [ "Stock", "Bond" ], result.type_entries.map(&:label)
    assert_in_delta 2.0 / 3, result.type_entries.first.ratio.to_f, 0.000001
    assert_in_delta 1.0 / 3, result.type_entries.second.ratio.to_f, 0.000001
    assert_equal [ "type:stock", "type:bond" ], result.type_entries.map(&:color_key)
    assert_equal [ "AAA", "BBB" ], result.position_entries.map(&:label)
    assert_equal [ "position:1", "position:2" ], result.position_entries.map(&:color_key)
  end

  test "omits zero values from both charts and keeps the denominator positive" do
    stock = Instrument.new(id: 1, ticker: "AAA", exchange: "BVMF", asset_type: :stock)
    zero = Instrument.new(id: 2, ticker: "ZERO", exchange: "BVMF", asset_type: :stock)

    result = Position::Allocation.for(
      positions: [ presenter(stock, "100"), presenter(zero, "0") ], reporting_currency: "BRL"
    )

    assert_equal [ "AAA" ], result.position_entries.map(&:label)
    assert_equal [ "Stock" ], result.type_entries.map(&:label)
    assert_equal BigDecimal("1"), result.position_entries.sole.ratio
  end

  test "returns an empty allocation for missing or non-positive open values" do
    missing_position = Presenter.new(false, nil, ValuationState.new(nil), Instrument.new(asset_type: :stock))
    zero_value = Instrument.new(id: 1, ticker: "ZERO", exchange: "BVMF", asset_type: :stock)

    assert_predicate Position::Allocation.for(positions: [ missing_position ], reporting_currency: "BRL"), :empty?
    assert_predicate Position::Allocation.for(
      positions: [ presenter(zero_value, "0") ], reporting_currency: "BRL"
    ), :empty?
  end

  test "ignores closed positions and reports an empty allocation when none remain" do
    instrument = Instrument.new(id: 1, ticker: "CLOSED", exchange: "BVMF", asset_type: :stock)
    closed = Presenter.new(false, PositionState.new(false), ValuationState.new(nil), instrument)

    result = Position::Allocation.for(positions: [ closed ], reporting_currency: "BRL")

    assert_predicate result, :empty?
    assert_empty result.type_entries
    assert_empty result.position_entries
  end

  test "does not present a partial allocation when an open value is unavailable" do
    available = Instrument.new(id: 1, ticker: "AAA", exchange: "BVMF", asset_type: :stock)
    missing = Instrument.new(id: 2, ticker: "BBB", exchange: "BVMF", asset_type: :bond)

    result = Position::Allocation.for(
      positions: [ presenter(available, "100"), presenter(missing, nil) ], reporting_currency: "BRL"
    )

    assert_predicate result, :unavailable?
    assert_empty result.type_entries
  end

  test "does not present an allocation when a position is invalid" do
    instrument = Instrument.new(id: 1, ticker: "BAD", exchange: "BVMF", asset_type: :other)
    invalid = Presenter.new(true, nil, ValuationState.new(nil), instrument)

    result = Position::Allocation.for(positions: [ invalid ], reporting_currency: "BRL")

    assert_predicate result, :unavailable?
  end

  private

  def presenter(instrument, amount)
    Presenter.new(false, PositionState.new(true), ValuationState.new(
      amount && Money.from_amount(BigDecimal(amount), "BRL")
    ), instrument)
  end
end
