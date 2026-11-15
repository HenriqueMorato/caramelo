require "test_helper"

class Performance::StaleRefreshRecoveryTest < ActiveJob::TestCase
  QueueActivityStub = Struct.new(:active, :arguments) do
    def active_job?(**)
      yield(arguments || {}) if block_given?
      active
    end
  end

  setup do
    Rails.cache.clear
    clear_enqueued_jobs
    @user = users(:owner)
    @instrument = instruments(:voo_arcx)
    @from = Date.new(2026, 8, 1)
    @to = Date.new(2026, 9, 1)
    @materialization = InstrumentPerformanceMaterialization.for(
      user: @user, instrument: @instrument, reporting_currency: "USD"
    )
    @materialization.update!(requested_from: nil, requested_to: nil)
  end

  test "releases an orphaned active lease and requeues the requested range" do
    @materialization.request!(from: @from, to: @to)
    old_token = Performance::SeriesRefresh.acquire(
      user: @user, instrument: @instrument, reporting_currency: "USD"
    )
    Performance::SeriesRefresh.running(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      from: @from, to: @to, token: old_token, phase: "fetching"
    )

    travel 6.minutes do
      result = recover

      assert_equal 1, result.recovered_count
      assert result.changed?
      assert_enqueued_jobs 1, only: BuildInstrumentPerformanceObservationsJob
      assert_equal "queued", refresh_state.status
      assert_not_equal old_token, Performance::SeriesRefresh.lease_token(
        user: @user, instrument: @instrument, reporting_currency: "USD"
      )
    end
  end

  test "does not interrupt fresh active work" do
    @materialization.request!(from: @from, to: @to)
    token = Performance::SeriesRefresh.acquire(
      user: @user, instrument: @instrument, reporting_currency: "USD"
    )
    Performance::SeriesRefresh.running(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      from: @from, to: @to, token:
    )

    result = recover

    assert_equal 0, result.recovered_count
    assert_empty enqueued_jobs
    assert_equal "running", refresh_state.status
    assert_equal token, Performance::SeriesRefresh.lease_token(
      user: @user, instrument: @instrument, reporting_currency: "USD"
    )
  end

  test "does not replace a stale state while its queue job is still active" do
    @materialization.request!(from: @from, to: @to)
    token = Performance::SeriesRefresh.acquire(
      user: @user, instrument: @instrument, reporting_currency: "USD"
    )
    Performance::SeriesRefresh.running(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      from: @from, to: @to, token:
    )

    travel 6.minutes do
      result = recover(queue_activity: QueueActivityStub.new(true))

      assert_equal 0, result.recovered_count
      assert_empty enqueued_jobs
      assert_equal token, Performance::SeriesRefresh.lease_token(
        user: @user, instrument: @instrument, reporting_currency: "USD"
      )
    end
  end

  test "does not reclaim a synchronous rebuild" do
    @materialization.request!(from: @from, to: @to)
    token = Performance::SeriesRefresh.acquire(
      user: @user, instrument: @instrument, reporting_currency: "USD"
    )
    Performance::SeriesRefresh.running(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      from: @from, to: @to, token:
    )
    Performance::SeriesRefresh.mark_synchronous_execution(
      user: @user, instrument: @instrument, reporting_currency: "USD", token:
    )

    travel 6.minutes do
      result = recover

      assert_equal 0, result.recovered_count
      assert_empty enqueued_jobs
      assert_equal token, Performance::SeriesRefresh.lease_token(
        user: @user, instrument: @instrument, reporting_currency: "USD"
      )
    end
  ensure
    Performance::SeriesRefresh.release_synchronous_execution(
      user: @user, instrument: @instrument, reporting_currency: "USD", token:
    ) if token
  end

  test "does not release a lease while enqueueing is in flight" do
    @materialization.request!(from: @from, to: @to)
    token = Performance::SeriesRefresh.acquire(
      user: @user, instrument: @instrument, reporting_currency: "USD", transient_marker: :enqueue
    )
    Performance::SeriesRefresh.succeeded(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      from: @from, to: @to, token:
    )
    travel 6.minutes do
      result = recover

      assert_equal 0, result.recovered_count
      assert_empty enqueued_jobs
      assert_equal token, Performance::SeriesRefresh.lease_token(
        user: @user, instrument: @instrument, reporting_currency: "USD"
      )
    end
  ensure
    Performance::SeriesRefresh.release_enqueue_in_flight(
      user: @user, instrument: @instrument, reporting_currency: "USD", token:
    ) if token
  end

  test "releases an orphaned lease before requeueing when no state was published" do
    @materialization.request!(from: @from, to: @to)
    token = Performance::SeriesRefresh.acquire(
      user: @user, instrument: @instrument, reporting_currency: "USD"
    )

    travel 6.minutes do
      result = recover

      assert_equal 1, result.recovered_count
      assert_enqueued_jobs 1, only: BuildInstrumentPerformanceObservationsJob
      refute_equal token, Performance::SeriesRefresh.lease_token(
        user: @user, instrument: @instrument, reporting_currency: "USD"
      )
    end
  end

  test "requeues a pending materialization left after a completed refresh" do
    @materialization.request!(from: @from, to: @to)
    token = Performance::SeriesRefresh.acquire(
      user: @user, instrument: @instrument, reporting_currency: "USD"
    )
    Performance::SeriesRefresh.succeeded(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      from: @from, to: @to, token:
    )
    Performance::SeriesRefresh.release(
      user: @user, instrument: @instrument, reporting_currency: "USD", token:
    )

    travel 6.minutes do
      result = recover

      assert_equal 1, result.recovered_count
      assert result.changed?
      assert_enqueued_jobs 1, only: BuildInstrumentPerformanceObservationsJob
    end
  end

  test "does not automatically retry a recorded provider failure" do
    @materialization.request!(from: @from, to: @to)
    token = Performance::SeriesRefresh.acquire(
      user: @user, instrument: @instrument, reporting_currency: "USD"
    )
    Performance::SeriesRefresh.failed(
      user: @user, instrument: @instrument, reporting_currency: "USD",
      from: @from, to: @to, token:, error: RuntimeError.new("provider unavailable")
    )
    Performance::SeriesRefresh.release(
      user: @user, instrument: @instrument, reporting_currency: "USD", token:
    )

    travel 6.minutes do
      result = recover

      assert_equal 0, result.recovered_count
      assert_empty enqueued_jobs
    end
  end

  test "recovers a pending portfolio materialization" do
    materialization = PortfolioPerformanceMaterialization.for(user: @user, reporting_currency: "BRL")
    materialization.request!(from: @from, to: @to)

    travel 6.minutes do
      result = recover(
        queue_activity: QueueActivityStub.new(false, { user_id: @user.id, reporting_currency: "BRL" })
      )

      assert_equal 1, result.recovered_count
      assert result.changed?
      assert_enqueued_jobs 1, only: BuildPortfolioPerformanceObservationsJob
    end
  end

  test "recovers a pending materialization without cached refresh state" do
    @materialization.request!(from: @from, to: @to)

    travel 6.minutes do
      result = recover

      assert_equal 1, result.recovered_count
      assert_enqueued_jobs 1, only: BuildInstrumentPerformanceObservationsJob
    end
  end

  test "reports a recovery enqueue error without stopping the sweep" do
    @materialization.request!(from: @from, to: @to)
    reported = []

    travel 6.minutes do
      with_stubbed_method(Performance::SeriesRefresh, :enqueue, ->(**) { raise "queue unavailable" }) do
        with_stubbed_method(Rails.error, :report, ->(error, **) { reported << error }) do
          result = recover

          assert_equal 0, result.recovered_count
        end
      end
    end

    assert_equal "queue unavailable", reported.sole.message
  end

  test "counts a durable enqueue failure as a changed target" do
    @materialization.request!(from: @from, to: @to)

    travel 6.minutes do
      with_stubbed_method(Performance::SeriesRefresh, :enqueue, ->(**) { :failed }) do
        result = recover

        assert_equal 0, result.recovered_count
        assert_equal 1, result.changed_count
      end
    end
  end

  test "leaves a target unchanged when enqueue reports an active lease" do
    @materialization.request!(from: @from, to: @to)

    travel 6.minutes do
      with_stubbed_method(Performance::SeriesRefresh, :enqueue, ->(**) { :active }) do
        result = recover

        assert_equal 0, result.recovered_count
        assert_equal 0, result.changed_count
      end
    end
  end

  test "reports recovery errors without target identifiers" do
    recovery = Performance::StaleRefreshRecovery.new(
      now: Time.current, stale_after: 5.minutes, queue_activity: QueueActivityStub.new(false)
    )
    recovery.define_singleton_method(:materializations) { [ Object.new ] }
    reported = []

    with_stubbed_method(Rails.error, :report, ->(error, **) { reported << error }) do
      result = recovery.call

      assert_equal 0, result.recovered_count
      assert_includes reported.sole.message, "pending?"
    end
  end

  private

  def recover(queue_activity: QueueActivityStub.new(
    false, { user_id: @user.id, reporting_currency: "USD", instrument_id: @instrument.id }
  ))
    Performance::StaleRefreshRecovery.call(queue_activity:)
  end

  def refresh_state
    Performance::SeriesRefresh.read(user: @user, instrument: @instrument, reporting_currency: "USD")
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
