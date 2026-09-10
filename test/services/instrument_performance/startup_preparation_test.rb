require "test_helper"

class InstrumentPerformance::StartupPreparationTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    @user = users(:owner)
  end

  test "creates native and reporting requests from each instrument first trade" do
    domestic = instruments(:petr4_bvmf)
    first_domestic = Date.new(2026, 8, 1)
    @user.trades.create!(
      instrument: domestic, side: :buy, traded_on: first_domestic,
      quantity: 1, unit_price: 10, fees_cents: 0, currency: "BRL"
    )

    travel_to(Date.new(2026, 9, 9)) { InstrumentPerformance::StartupPreparation.call(user: @user) }

    foreign = instruments(:voo_arcx)
    foreign_states = @user.instrument_performance_materializations.where(instrument: foreign).index_by(&:reporting_currency)
    domestic_states = @user.instrument_performance_materializations.where(instrument: domestic).index_by(&:reporting_currency)
    assert_equal %w[BRL USD], foreign_states.keys.sort
    assert_equal [ "BRL" ], domestic_states.keys
    assert foreign_states.values.all? { |state| state.requested_from == trades(:owner_voo_buy).traded_on }
    assert_equal first_domestic, domestic_states.fetch("BRL").requested_from
    assert_enqueued_jobs 3, only: BuildInstrumentPerformanceObservationsJob
  end

  test "does nothing without current or historical trades" do
    Trade.where(user: @user).delete_all

    InstrumentPerformance::StartupPreparation.call(user: @user)

    assert_empty @user.instrument_performance_materializations
    assert_no_enqueued_jobs only: BuildInstrumentPerformanceObservationsJob
  end
end
