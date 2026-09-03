require "test_helper"

class BuildPortfolioPerformanceObservationsJobTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    @user = users(:owner)
    @from = Date.new(2026, 9, 1)
    @to = Date.new(2026, 9, 2)
    @materialization = PortfolioPerformanceMaterialization.for(user: @user)
    @materialization.request!(from: @from, to: @to)
  end

  test "builds the durable requested range and records success" do
    builder = RecordingBuilder.new

    with_builder(builder) { perform_job }

    assert_equal [ { from: @from, to: @to } ], builder.calls
    assert_equal "succeeded", refresh_state.status
    assert_not_predicate @materialization.reload, :pending?
  end

  test "records failure while retaining the durable request for retry" do
    builder = RecordingBuilder.new(error: RuntimeError.new("calculation failed"))

    with_builder(builder) do
      error = assert_raises(RuntimeError) { perform_job }
      assert_equal "calculation failed", error.message
    end

    assert_equal "failed", refresh_state.status
    assert_predicate @materialization.reload, :pending?
    assert_no_enqueued_jobs only: BuildPortfolioPerformanceObservationsJob
  end

  test "requeues a newer invalidation after releasing the active lease" do
    @lease_token = Performance::SeriesRefresh.acquire(user: @user)
    builder = RecordingBuilder.new do
      @materialization.request!(from: @from - 1.day, to: @to, source_changed: true)
    end

    with_builder(builder) { perform_job }

    assert_predicate @materialization.reload, :pending?
    assert_equal @from - 1.day, @materialization.requested_from
    assert_equal "queued", refresh_state.status
    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
  end

  test "ignores a completed request left in the queue" do
    @materialization.complete!(source_generation: 0, from: @from, to: @to)

    assert_nil perform_job
    assert_no_enqueued_jobs only: BuildPortfolioPerformanceObservationsJob
  end

  test "reraises a missing user without writing refresh state" do
    assert_raises(ActiveRecord::RecordNotFound) do
      BuildPortfolioPerformanceObservationsJob.perform_now(
        user_id: -1, reporting_currency: "BRL", lease_token: "missing-user"
      )
    end
  end

  private

  def perform_job
    @lease_token ||= Performance::SeriesRefresh.acquire(user: @user)
    BuildPortfolioPerformanceObservationsJob.perform_now(
      user_id: @user.id, reporting_currency: "BRL", lease_token: @lease_token
    )
  end

  def refresh_state
    Performance::SeriesRefresh.read(user: @user)
  end

  def with_builder(builder)
    original = Performance::ObservationBuilder.method(:new)
    Performance::ObservationBuilder.define_singleton_method(:new, ->(**) { builder })
    yield
  ensure
    Performance::ObservationBuilder.define_singleton_method(:new, original)
  end

  class RecordingBuilder
    attr_reader :calls

    def initialize(error: nil, &during_build)
      @error = error
      @during_build = during_build
      @calls = []
    end

    def call(**arguments)
      calls << arguments
      raise @error if @error

      @during_build&.call
      Performance::ObservationBuilder::Result.new(
        **arguments, built_count: 2, skipped_count: 0, source_generation: 0
      )
    end
  end
end
