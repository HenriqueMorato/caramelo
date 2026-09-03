require "test_helper"

class TradePerformanceInvalidationTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    @user = users(:owner)
    @trade = trades(:owner_voo_buy)
    @state = PortfolioPerformanceMaterialization.for(user: @user)
  end

  test "creation durably records its date before enqueueing" do
    trade = @trade.dup
    trade.traded_on = Date.new(2026, 7, 1)
    trade.save!

    assert_equal trade.traded_on, @state.reload.requested_from
    assert_equal 1, @state.source_generation
    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
  end

  test "moving a date earlier or later invalidates the earliest affected date" do
    original_date = @trade.traded_on
    @trade.update!(traded_on: original_date + 2.days)
    assert_equal original_date, @state.reload.requested_from

    @trade.update!(traded_on: original_date - 2.days)
    assert_equal original_date - 2.days, @state.reload.requested_from
    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
  end

  test "reassignment invalidates both owners" do
    other_user = users(:one)
    @trade.update!(user: other_user, institution: nil)

    [ @user, other_user ].each do |user|
      state = PortfolioPerformanceMaterialization.for(user:)
      assert_equal @trade.traded_on, state.requested_from
      assert_equal 1, state.source_generation
    end
    assert_enqueued_jobs 2, only: BuildPortfolioPerformanceObservationsJob
  end

  test "source edits invalidate previously used reporting currencies as well" do
    alternate = PortfolioPerformanceMaterialization.for(user: @user, reporting_currency: "USD")

    @trade.update!(quantity: "3")

    assert_equal 1, @state.reload.source_generation
    assert_equal 1, alternate.reload.source_generation
    assert_equal @trade.traded_on, alternate.requested_from
    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
  end

  test "deleting the last trade queues a cleanup that cannot recreate its history" do
    @trade.destroy!

    perform_enqueued_jobs(only: BuildPortfolioPerformanceObservationsJob)

    assert_empty @user.portfolio_performance_observations
    assert_not_predicate @state.reload, :pending?
  end

  test "a later notes edit on the same instance does not reuse old invalidation targets" do
    @trade.update!(quantity: "3")
    generation = @state.reload.source_generation
    clear_enqueued_jobs
    Rails.cache.clear

    @trade.update!(notes: "Only explanatory text changed")

    assert_equal generation, @state.reload.source_generation
    assert_no_enqueued_jobs only: BuildPortfolioPerformanceObservationsJob
  end

  test "source and durable invalidation roll back together when marking fails" do
    original_quantity = @trade.quantity
    original = Performance::ObservationInvalidator.method(:mark!)
    Performance::ObservationInvalidator.define_singleton_method(:mark!, lambda { |**arguments|
      original.call(**arguments)
      raise "invalidation unavailable"
    })

    assert_raises(RuntimeError) { @trade.update!(quantity: "9") }

    assert_equal original_quantity, @trade.reload.quantity
    assert_equal 0, @state.reload.source_generation
    assert_not_predicate @state, :pending?
    assert_no_enqueued_jobs only: BuildPortfolioPerformanceObservationsJob
  ensure
    Performance::ObservationInvalidator.define_singleton_method(:mark!, original)
  end

  test "bulk trade creation coalesces into one earliest rebuild request" do
    dates = (Date.new(2026, 8, 14)..Date.new(2026, 9, 1)).to_a
    Trade.transaction do
      dates.each do |date|
        @trade.dup.tap { |trade| trade.traded_on = date }.save!
      end
    end

    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
    assert_equal dates.first, @state.reload.requested_from
    assert_equal dates.length, @state.source_generation
  end
end
