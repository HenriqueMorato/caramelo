require "test_helper"

class PositionMaterializations::RefreshTest < ActiveSupport::TestCase
  setup do
    @user = users(:owner)
    @instrument = instruments(:voo_arcx)
    @materialization = PositionMaterialization.create!(user: @user, instrument: @instrument)
    @trades = @user.trades.where(instrument: @instrument).order(:traded_on, :id).to_a
  end

  test "replays trades and stores a complete projection" do
    PositionMaterializations::Refresh.call(materialization: @materialization)

    @materialization.reload
    position = Position.for(instrument: @instrument, trades: @trades)
    assert_predicate @materialization, :complete?
    assert_equal position.quantity, @materialization.quantity
    assert_equal position.analytical_cost_basis_amount, @materialization.cost_basis_amount
    assert_equal @trades.last.id, @materialization.source_trade_id
    assert_equal @trades.last.updated_at, @materialization.source_trade_updated_at
  end

  test "records invalid long-only data without raising" do
    sell = @user.trades.create!(instrument: @instrument, side: :sell, traded_on: Date.current,
      quantity: 3, unit_price: 10, currency: @instrument.currency)
    materialization = @materialization

    result = PositionMaterializations::Refresh.call(materialization:)

    assert_equal materialization, result
    assert_predicate materialization.reload, :failed?
    assert_equal Position::InvalidLongOnlyData.name, materialization.error_class
    assert_includes materialization.error_message, sell.id.to_s
  end

  test "does not publish a result after the source generation advances" do
    position = Position.for(instrument: @instrument, trades: @trades)
    materialization = @materialization
    with_stubbed_method(Position, :for, ->(**) {
      materialization.queue_refresh!
      position
    }) do
      PositionMaterializations::Refresh.call(materialization: @materialization)
    end

    assert_equal "pending", @materialization.reload.status
    assert_nil @materialization.calculated_at
  end

  test "does not publish a failure after the source generation advances" do
    failure = Position::InvalidLongOnlyData.new(@trades.first)
    materialization = @materialization
    with_stubbed_method(Position, :for, ->(**) {
      materialization.queue_refresh!
      raise failure
    }) do
      PositionMaterializations::Refresh.call(materialization: @materialization)
    end

    assert_equal "pending", @materialization.reload.status
    assert_nil @materialization.error_class
  end

  test "refreshes an instrument with no trades" do
    instrument = Instrument.create!(ticker: "EMPTY", exchange: "XNAS", name: "Empty Instrument", currency: "USD")
    materialization = PositionMaterialization.create!(user: @user, instrument:)

    PositionMaterializations::Refresh.call(materialization:)

    assert_predicate materialization.reload, :complete?
    assert_nil materialization.source_trade_id
    assert_nil materialization.source_trade_updated_at
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, &replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
