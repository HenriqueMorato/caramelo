require "test_helper"

class BuildInstrumentPerformanceObservationsJobTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    @user = users(:owner)
    @instrument = instruments(:voo_arcx)
    @from = Date.new(2026, 9, 1)
    @to = Date.new(2026, 9, 2)
    @materialization = InstrumentPerformanceMaterialization.for(
      user: @user, instrument: @instrument, reporting_currency: "USD"
    )
    @materialization.request!(from: @from, to: @to)
  end

  test "builds the durable instrument range and records success" do
    builder = RecordingBuilder.new

    with_builder(builder) { perform_job }

    assert_equal [ { from: @from, to: @to } ], builder.calls
    assert_equal "succeeded", refresh_state.status
    assert_not_predicate @materialization.reload, :pending?
  end

  test "records failure and resumes only after a later request" do
    builder = RecordingBuilder.new(error: RuntimeError.new("instrument calculation failed"))

    with_builder(builder) do
      error = assert_raises(RuntimeError) { perform_job }
      assert_equal "instrument calculation failed", error.message
    end

    assert_equal "failed", refresh_state.status
    assert_predicate @materialization.reload, :pending?
    assert_no_enqueued_jobs only: BuildInstrumentPerformanceObservationsJob
  end

  test "requeues an overlapping newer generation after releasing the target lease" do
    @lease_token = acquire
    builder = RecordingBuilder.new do
      @materialization.request!(from: @from - 1.day, to: @to, source_changed: true)
    end

    with_builder(builder) { perform_job }

    assert_equal @from - 1.day, @materialization.reload.requested_from
    assert_equal "queued", refresh_state.status
    assert_enqueued_jobs 1, only: BuildInstrumentPerformanceObservationsJob
  end

  test "ignores completed work left in the queue" do
    @materialization.complete!(source_generation: 0, from: @from, to: @to)

    assert_nil perform_job
    assert_no_enqueued_jobs only: BuildInstrumentPerformanceObservationsJob
  end

  test "reraises a missing instrument without writing state" do
    assert_raises(ActiveRecord::RecordNotFound) do
      BuildInstrumentPerformanceObservationsJob.perform_now(
        user_id: @user.id,
        instrument_id: -1,
        reporting_currency: "USD",
        lease_token: "missing-instrument"
      )
    end
  end

  private

  def acquire
    Performance::SeriesRefresh.acquire(user: @user, instrument: @instrument, reporting_currency: "USD")
  end

  def perform_job
    @lease_token ||= acquire
    BuildInstrumentPerformanceObservationsJob.perform_now(
      user_id: @user.id,
      instrument_id: @instrument.id,
      reporting_currency: "USD",
      lease_token: @lease_token
    )
  end

  def refresh_state
    Performance::SeriesRefresh.read(user: @user, instrument: @instrument, reporting_currency: "USD")
  end

  def with_builder(builder)
    original = Performance::ObservationBuilder.method(:new)
    instrument = @instrument
    Performance::ObservationBuilder.define_singleton_method(:new, ->(**arguments) {
      raise "instrument target missing" unless arguments[:instrument] == instrument

      builder
    })
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
