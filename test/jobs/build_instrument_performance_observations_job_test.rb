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

    entry = MarketData::HealthReport::InstrumentPerformance.new(owner: @user, today: @to).entries.find do |candidate|
      candidate.subject == @instrument && candidate.target.quote_currency == "USD"
    end
    assert_equal :failed, entry.status
    assert_equal [ :retry ], entry.actions
  end

  test "keeps the durable failure when the health broadcast fails" do
    calculation_error = RuntimeError.new("instrument calculation failed")
    broadcast_error = RuntimeError.new("broadcast unavailable")
    reported = []

    with_stubbed_method(MarketData::HealthReportBroadcaster, :refresh, -> { raise broadcast_error }) do
      with_stubbed_method(Rails.error, :report, ->(error, **) { reported << error }) do
        with_builder(RecordingBuilder.new(error: calculation_error)) do
          assert_raises(RuntimeError) { perform_job }
        end
      end
    end

    assert_equal "failed", refresh_state.status
    assert_predicate @materialization.reload, :pending?
    assert_includes reported, broadcast_error
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

  test "marks an obsolete queued refresh successful" do
    @lease_token = acquire
    Performance::SeriesRefresh.queued(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      from: @from, to: @to, token: @lease_token
    )
    @materialization.complete!(source_generation: 0, from: @from, to: @to)

    assert_nil perform_job
    assert_equal "succeeded", refresh_state.status
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

  test "limits concurrent work per owner instrument and currency" do
    job = BuildInstrumentPerformanceObservationsJob.new(
      user_id: @user.id,
      instrument_id: @instrument.id,
      reporting_currency: "USD",
      lease_token: "lease"
    )

    assert_equal :block, BuildInstrumentPerformanceObservationsJob.concurrency_on_conflict
    assert_equal 1, BuildInstrumentPerformanceObservationsJob.concurrency_limit
    assert_equal 30.minutes, BuildInstrumentPerformanceObservationsJob.concurrency_duration
    assert_equal "BuildInstrumentPerformanceObservationsJob/instrument_performance:#{@user.id}:#{@instrument.id}:USD",
      job.concurrency_key
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

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name) { |*args, **kwargs| replacement.call(*args, **kwargs) }
    yield
  ensure
    object.define_singleton_method(method_name, original)
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
