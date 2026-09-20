require "test_helper"

class InstrumentPerformance::StartupPreparationTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    @user = users(:owner)
  end

  test "creates native and reporting requests from each instrument first activity" do
    domestic = instruments(:petr4_bvmf)
    first_domestic = Date.new(2026, 8, 1)
    @user.trades.create!(
      instrument: domestic, side: :buy, traded_on: first_domestic,
      quantity: 1, unit_price: 10, fees_cents: 0, currency: "BRL"
    )
    first_domestic_activity = first_domestic - 2.days
    CorporateAction.create!(
      user: @user, instrument: domestic, kind: :dividend, status: :confirmed,
      paid_on: first_domestic_activity, gross_amount_cents: 1_000,
      withholding_tax_cents: 0, net_amount_cents: 1_000,
      currency: domestic.currency, source: "manual"
    )
    @user.instrument_performance_materializations.delete_all
    clear_enqueued_jobs
    Rails.cache.clear

    travel_to(Date.new(2026, 9, 9)) { InstrumentPerformance::StartupPreparation.call(user: @user) }

    foreign = instruments(:voo_arcx)
    foreign_states = @user.instrument_performance_materializations.where(instrument: foreign).index_by(&:reporting_currency)
    domestic_states = @user.instrument_performance_materializations.where(instrument: domestic).index_by(&:reporting_currency)
    assert_equal %w[BRL USD], foreign_states.keys.sort
    assert_equal [ "BRL" ], domestic_states.keys
    assert foreign_states.values.all? { |state| state.requested_from == trades(:owner_voo_buy).traded_on }
    assert_equal first_domestic_activity, domestic_states.fetch("BRL").requested_from
    assert_enqueued_jobs 3, only: BuildInstrumentPerformanceObservationsJob
  end

  test "creates requests for an instrument with income but no trades" do
    Trade.where(user: @user).delete_all
    instrument = instruments(:voo_arcx)
    action = CorporateAction.create!(
      user: @user, instrument:, kind: :dividend, status: :confirmed,
      paid_on: Date.new(2026, 8, 20), ex_date: Date.new(2026, 8, 15),
      gross_amount_cents: 1_000, withholding_tax_cents: 0, net_amount_cents: 1_000,
      currency: instrument.currency, source: "manual"
    )
    @user.instrument_performance_materializations.delete_all
    clear_enqueued_jobs
    Rails.cache.clear

    travel_to(Date.new(2026, 9, 9)) { InstrumentPerformance::StartupPreparation.call(user: @user) }

    states = @user.instrument_performance_materializations.where(instrument:).index_by(&:reporting_currency)
    assert_equal %w[BRL USD], states.keys.sort
    assert states.values.all? { |state| state.requested_from == action.ex_date }
    assert_enqueued_jobs 2, only: BuildInstrumentPerformanceObservationsJob
  end

  test "does nothing without current or historical activity" do
    Trade.where(user: @user).delete_all
    CorporateAction.where(user: @user).delete_all

    InstrumentPerformance::StartupPreparation.call(user: @user)

    assert_empty @user.instrument_performance_materializations
    assert_no_enqueued_jobs only: BuildInstrumentPerformanceObservationsJob
  end
end
