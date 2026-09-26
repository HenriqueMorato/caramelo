require "test_helper"

class CorporateActionPerformanceInvalidationTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    @user = users(:owner)
    @instrument = instruments(:petr4_bvmf)
    @date = Date.new(2026, 8, 20)
    @state = PortfolioPerformanceMaterialization.for(user: @user)
  end

  test "confirmed creation durably invalidates portfolio and instrument histories" do
    action = build_action

    action.save!

    assert_equal @date, @state.reload.requested_from
    assert_equal 1, @state.source_generation
    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
    assert_enqueued_jobs 1, only: BuildInstrumentPerformanceObservationsJob
  end

  test "pending creation is inert until confirmation" do
    action = build_action(status: :pending)
    action.save!

    assert_equal 0, @state.reload.source_generation
    assert_no_enqueued_jobs only: BuildPortfolioPerformanceObservationsJob

    action.update!(status: :confirmed)

    assert_equal 1, @state.reload.source_generation
    assert_equal @date, @state.requested_from
    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
  end

  test "reversal invalidates the formerly effective date" do
    action = create_action
    reset_invalidation_state

    action.update!(status: :reversed)

    assert_equal @date, @state.reload.requested_from
    assert_equal 1, @state.source_generation
  end

  test "moving the effective date invalidates from the earlier boundary" do
    action = create_action
    reset_invalidation_state

    action.update!(paid_on: @date + 3.days)
    assert_equal @date, @state.reload.requested_from

    reset_invalidation_state
    action.update!(paid_on: @date - 2.days)
    assert_equal @date - 2.days, @state.reload.requested_from
  end

  test "adding and moving an ex-date invalidates from the earliest effective boundary" do
    action = create_action
    reset_invalidation_state

    action.update!(ex_date: @date - 4.days)
    assert_equal @date - 4.days, @state.reload.requested_from

    reset_invalidation_state
    action.update!(ex_date: @date - 2.days)
    assert_equal @date - 4.days, @state.reload.requested_from
  end

  test "moving an action invalidates both old and new instruments" do
    action = create_action
    old_instrument = action.instrument
    new_instrument = instruments(:voo_arcx)
    reset_invalidation_state

    action.update!(instrument: new_instrument, currency: new_instrument.currency, institution: nil)

    [ old_instrument, new_instrument ].each do |instrument|
      states = @user.instrument_performance_materializations.where(instrument:)
      assert_equal [ instrument.currency, @user.reporting_currency ].uniq.sort,
        states.pluck(:reporting_currency).sort
      assert states.all? { |state| state.requested_from == @date && state.source_generation == 1 }
    end
  end

  test "deletion removes the distribution from subsequent performance" do
    action = create_action
    reset_invalidation_state

    action.destroy!

    assert_equal @date, @state.reload.requested_from
    assert_equal 1, @state.source_generation
    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
  end

  test "notes edits do not rebuild identical accounting" do
    action = create_action
    reset_invalidation_state

    action.update!(notes: "Reinvested later")

    assert_equal 0, @state.reload.source_generation
    assert_no_enqueued_jobs only: BuildPortfolioPerformanceObservationsJob
  end

  test "quantity actions invalidate performance and refresh current positions" do
    materialization = PositionMaterialization.create!(user: @user, instrument: @instrument)
    action = build_quantity_action

    assert_enqueued_with(
      job: RefreshPositionMaterializationJob,
      args: [ { user_id: @user.id, instrument_id: @instrument.id } ]
    ) { action.save! }

    assert_equal @date, @state.reload.requested_from
    assert_equal 1, @state.source_generation
    assert_equal 1, materialization.reload.source_generation
    assert_predicate materialization, :pending?
  end

  test "reversing and moving a quantity action refreshes every affected position" do
    old_materialization = PositionMaterialization.create!(user: @user, instrument: @instrument)
    action = build_quantity_action.tap(&:save!)
    new_instrument = instruments(:voo_arcx)
    new_materialization = PositionMaterialization.create!(user: @user, instrument: new_instrument)
    clear_enqueued_jobs

    action.update!(instrument: new_instrument)

    assert_equal 2, old_materialization.reload.source_generation
    assert_equal 1, new_materialization.reload.source_generation
    assert_enqueued_jobs 2, only: RefreshPositionMaterializationJob

    clear_enqueued_jobs
    action.update!(status: :reversed)

    assert_equal 2, new_materialization.reload.source_generation
    assert_enqueued_jobs 1, only: RefreshPositionMaterializationJob
  end

  test "source and invalidation roll back together when marking fails" do
    action = create_action
    original_amount = action.net_amount_cents
    reset_invalidation_state
    original = Performance::ObservationInvalidator.method(:mark!)
    Performance::ObservationInvalidator.define_singleton_method(:mark!, lambda { |**arguments|
      original.call(**arguments)
      raise "invalidation unavailable"
    })

    assert_raises(RuntimeError) do
      action.update!(gross_amount_cents: 2_000, net_amount_cents: 1_850)
    end

    assert_equal original_amount, action.reload.net_amount_cents
    assert_equal 0, @state.reload.source_generation
  ensure
    Performance::ObservationInvalidator.define_singleton_method(:mark!, original)
  end

  private

  def build_action(status: :confirmed)
    CorporateAction.new(
      user: @user, instrument: @instrument, institution: institutions(:owner_xp),
      kind: :dividend, status:, paid_on: @date,
      gross_amount_cents: 1_000, withholding_tax_cents: 150, net_amount_cents: 850,
      currency: @instrument.currency, source: "manual"
    )
  end

  def create_action
    build_action.tap(&:save!)
  end

  def build_quantity_action
    CorporateAction.new(
      user: @user, instrument: @instrument, institution: institutions(:owner_xp),
      kind: :stock_split, status: :confirmed, effective_on: @date,
      ratio_numerator: 2, ratio_denominator: 1, source: "manual"
    )
  end

  def reset_invalidation_state
    clear_enqueued_jobs
    Rails.cache.clear
    [ PortfolioPerformanceMaterialization, InstrumentPerformanceMaterialization ].each do |model|
      model.update_all(source_generation: 0, requested_from: nil, requested_to: nil)
    end
    @state.reload
  end
end
