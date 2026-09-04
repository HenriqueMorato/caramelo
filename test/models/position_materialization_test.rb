require "test_helper"

class PositionMaterializationTest < ActiveJob::TestCase
  setup do
    @user = users(:owner)
    @instrument = instruments(:petr4_bvmf)
    @materialization = PositionMaterialization.create!(user: @user, instrument: @instrument)
  end

  test "starts pending and becomes stale when the source trade changes" do
    assert_predicate @materialization, :stale?

    @materialization.update!(status: "complete", source_trade_id: nil, source_trade_updated_at: nil)
    assert_not_predicate @materialization, :stale?

    @materialization.queue_refresh!
    assert_predicate @materialization, :stale?
    assert_equal "pending", @materialization.status
  end

  test "enforces one projection per owner and instrument" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      PositionMaterialization.create!(user: @user, instrument: @instrument)
    end
  end

  test "becomes stale when the latest trade is edited" do
    trade = @user.trades.create!(instrument: @instrument, side: :buy, traded_on: Date.current,
      quantity: 1, unit_price: 10, currency: @instrument.currency)
    @materialization.update!(status: "complete", source_trade_id: trade.id,
      source_trade_updated_at: trade.updated_at)

    trade.update!(notes: "corrected")

    assert_predicate @materialization.reload, :stale?
  end

  test "exposes status predicates and latest source trade metadata" do
    trade = @user.trades.create!(instrument: @instrument, side: :buy, traded_on: Date.current,
      quantity: 1, unit_price: 10, currency: @instrument.currency)

    @materialization.update!(status: "failed")
    assert_predicate @materialization, :failed?
    assert_not_predicate @materialization, :complete?
    @materialization.update!(status: "refreshing")
    assert_predicate @materialization, :refreshing?
    assert_equal trade.id, @materialization.latest_trade_id
    assert_equal trade.updated_at, @materialization.latest_trade_updated_at
  end

  test "trade changes enqueue a refresh and advance an existing projection" do
    assert_enqueued_with(job: RefreshPositionMaterializationJob,
      args: [ { user_id: @user.id, instrument_id: @instrument.id } ]) do
      @user.trades.create!(instrument: @instrument, side: :buy, traded_on: Date.current,
        quantity: 1, unit_price: 10, currency: @instrument.currency)
    end

    assert_equal 1, @materialization.reload.source_generation
    assert_predicate @materialization, :stale?
  end

  test "reassignment enqueues refreshes for both source and destination" do
    other_instrument = Instrument.create!(ticker: "OTHER", exchange: "BVMF",
      name: "Other BRL Instrument", currency: "BRL")
    assert_enqueued_jobs 3, only: RefreshPositionMaterializationJob do
      trade = @user.trades.create!(instrument: @instrument, side: :buy, traded_on: Date.current,
        quantity: 1, unit_price: 10, currency: @instrument.currency)
      trade.update!(instrument: other_instrument)
    end
  end
end
