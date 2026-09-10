require "test_helper"

class Performance::SeriesRefreshTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    @user = users(:owner)
    @from = Date.new(2026, 8, 1)
    @to = Date.new(2026, 9, 1)
    @materialization = PortfolioPerformanceMaterialization.for(user: @user)
  end

  test "atomically enqueues one build and coalesces overlapping ranges" do
    assert_equal :queued, enqueue
    assert_equal :queued, Performance::SeriesRefresh.enqueue(
      user: @user, from: @from - 1.month, to: Date.current
    )

    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
    assert_equal @from - 1.month, @materialization.reload.requested_from
    assert_equal Date.current, @materialization.requested_to
    assert_predicate refresh_state, :active?
  end

  test "keeps instrument currency targets independent from portfolio and peers" do
    instrument = instruments(:voo_arcx)
    other = instruments(:petr4_bvmf)
    portfolio_token = Performance::SeriesRefresh.acquire(user: @user)
    instrument_token = Performance::SeriesRefresh.acquire(
      user: @user, instrument:, reporting_currency: "USD"
    )

    assert portfolio_token
    assert instrument_token
    assert Performance::SeriesRefresh.acquire(user: @user, instrument: other, reporting_currency: "BRL")
    assert Performance::SeriesRefresh.acquire(user: @user, instrument:, reporting_currency: "BRL")
    assert_not Performance::SeriesRefresh.acquire(user: @user, instrument:, reporting_currency: "USD")
  end

  test "enqueues and reads target-scoped instrument state" do
    instrument = instruments(:voo_arcx)

    assert_equal :queued, Performance::SeriesRefresh.enqueue(
      user: @user, instrument:, reporting_currency: "USD", from: @from, to: @to
    )

    job = enqueued_jobs.find { |item| item[:job] == BuildInstrumentPerformanceObservationsJob }
    arguments = job.fetch(:args).sole.symbolize_keys
    assert_equal @user.id, arguments.fetch(:user_id)
    assert_equal instrument.id, arguments.fetch(:instrument_id)
    assert_equal "USD", arguments.fetch(:reporting_currency)
    assert_instance_of String, arguments.fetch(:lease_token)
    state = Performance::SeriesRefresh.read(user: @user, instrument:, reporting_currency: "USD")
    assert_equal "queued", state.status
    assert_nil Performance::SeriesRefresh.read(user: @user)
  end

  test "reports an existing running build as active" do
    token = Performance::SeriesRefresh.acquire(user: @user)
    Performance::SeriesRefresh.running(user: @user, from: @from, to: @to, token:)

    assert_equal :active, enqueue
  end

  test "exposes running successful and failed states" do
    token = Performance::SeriesRefresh.acquire(user: @user)
    Performance::SeriesRefresh.running(user: @user, from: @from, to: @to, token:)
    assert_equal "running", refresh_state.status

    Performance::SeriesRefresh.succeeded(user: @user, from: @from, to: @to, token:)
    assert_equal "succeeded", refresh_state.status

    Performance::SeriesRefresh.failed(
      user: @user, from: @from, to: @to, token:,
      error: RuntimeError.new("provider history unavailable")
    )
    assert_equal "failed", refresh_state.status
    assert_equal "provider history unavailable", refresh_state.error_message
  end

  test "holds a recent failure before allowing a retry" do
    token = Performance::SeriesRefresh.acquire(user: @user)
    Performance::SeriesRefresh.failed(
      user: @user, from: @from, to: @to, token:, error: RuntimeError.new("failed")
    )
    Performance::SeriesRefresh.release(user: @user, token:)

    assert_equal :failed, enqueue
    assert_no_enqueued_jobs only: BuildPortfolioPerformanceObservationsJob

    travel 31.seconds

    assert_equal :queued, enqueue
  end

  test "recovers when active cache state outlives its lease" do
    token = Performance::SeriesRefresh.acquire(user: @user)
    Performance::SeriesRefresh.running(user: @user, from: @from, to: @to, token:)
    Performance::SeriesRefresh.release(user: @user, token:)

    assert_equal :queued, enqueue
    assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
  end

  test "reports an enqueue failure and releases its lease" do
    job_class = Class.new do
      def self.perform_later(**)
        raise ActiveJob::EnqueueError, "queue unavailable"
      end
    end
    reported = []

    with_stubbed_method(Rails.error, :report, ->(error, **) { reported << error }) do
      assert_equal :failed, Performance::SeriesRefresh.enqueue(
        user: @user, from: @from, to: @to, job_class:
      )
    end

    assert_equal "queue unavailable", reported.first.message
    travel 31.seconds
    assert_equal :queued, enqueue
  end

  test "reports an instrument enqueue failure with target context" do
    instrument = instruments(:voo_arcx)
    job_class = Class.new do
      def self.perform_later(**)
        raise ActiveJob::EnqueueError, "instrument queue unavailable"
      end
    end
    reports = []

    with_stubbed_method(Rails.error, :report, ->(error, **details) { reports << [ error, details ] }) do
      assert_equal :failed, Performance::SeriesRefresh.enqueue(
        user: @user, instrument:, reporting_currency: "USD", from: @from, to: @to, job_class:
      )
    end

    error, details = reports.sole
    assert_equal "instrument queue unavailable", error.message
    assert_equal instrument.id, details.fetch(:context).fetch(:instrument_id)
  end

  test "treats an existing owner lease as active for every range" do
    assert Performance::SeriesRefresh.acquire(user: @user)

    assert_equal :active, enqueue
    assert_no_enqueued_jobs only: BuildPortfolioPerformanceObservationsJob
  end

  test "reports when an adapter declines the enqueue" do
    declined_job = Struct.new(:successfully_enqueued?).new(false)
    job_class = Class.new do
      class << self
        attr_accessor :result

        def perform_later(**)
          result
        end
      end
    end
    job_class.result = declined_job
    reported = []

    with_stubbed_method(Rails.error, :report, ->(error, **) { reported << error }) do
      assert_equal :failed, Performance::SeriesRefresh.enqueue(
        user: @user, from: @from, to: @to, job_class:
      )
    end

    assert_instance_of ActiveJob::EnqueueError, reported.first
  end

  test "does not release another rebuild lease when a synchronous rebuild is rejected" do
    assert Performance::SeriesRefresh.acquire(user: @user)

    assert_raises(Performance::SeriesRefresh::AlreadyRunning) do
      Performance::SeriesRefresh.rebuild_now(user: @user, from: @from, to: @to)
    end

    assert_not Performance::SeriesRefresh.acquire(user: @user)
  end

  test "expired workers cannot clear a newer lease or overwrite its status" do
    old_token = Performance::SeriesRefresh.acquire(user: @user)
    travel 31.minutes
    new_token = Performance::SeriesRefresh.acquire(user: @user)
    Performance::SeriesRefresh.running(user: @user, from: @from, to: @to, token: new_token)

    Performance::SeriesRefresh.succeeded(user: @user, from: @from, to: @to, token: old_token)
    Performance::SeriesRefresh.release(user: @user, token: old_token)

    assert_equal "running", refresh_state.status
    assert_not Performance::SeriesRefresh.acquire(user: @user)
  end

  test "synchronous rebuilds use the same lease and durable completion path" do
    result = Performance::SeriesRefresh.rebuild_now(user: @user, from: @from, to: @from)

    assert_equal 1, result.built_count
    assert_equal "succeeded", refresh_state.status
    assert_not_predicate @materialization.reload, :pending?
    assert Performance::SeriesRefresh.acquire(user: @user)
  end

  test "releases a synchronous lease when dispatch preparation fails" do
    with_stubbed_method(Performance::SeriesRefresh, :queued, ->(**) { raise "cache unavailable" }) do
      assert_raises(RuntimeError) do
        Performance::SeriesRefresh.rebuild_now(user: @user, from: @from, to: @to)
      end
    end

    assert Performance::SeriesRefresh.acquire(user: @user)
  end

  test "ignores malformed cached state" do
    Rails.cache.write(state_key, { status: "running" })

    assert_nil refresh_state
  end

  test "ignores a cached value with the wrong shape" do
    Rails.cache.write(state_key, "invalid state")

    assert_nil refresh_state
    assert_equal :queued, enqueue
  end

  private

  def enqueue
    Performance::SeriesRefresh.enqueue(user: @user, from: @from, to: @to)
  end

  def refresh_state
    Performance::SeriesRefresh.read(user: @user)
  end

  def state_key
    "#{Performance::SeriesRefresh::CACHE_PREFIX}:#{@user.id}:BRL:state"
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
