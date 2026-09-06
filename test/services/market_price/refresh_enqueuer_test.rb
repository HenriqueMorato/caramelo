require "test_helper"

class MarketPrice::RefreshEnqueuerTest < ActiveSupport::TestCase
  setup { Rails.cache.clear }

  test "broadcasts refreshing before enqueueing the forced job" do
    events = []
    broadcaster = fake_broadcaster(events:)
    job = Object.new
    job_class = fake_job_class(events:, result: job)

    result = MarketPrice::RefreshEnqueuer.new(broadcaster:, job_class:).enqueue(
      instrument: instruments(:petr4_bvmf)
    )

    assert_same job, result
    assert_equal %i[ refreshing enqueue ], events
  end

  test "assigns the batch run to the target status" do
    events = []
    broadcaster = fake_broadcaster(events:)
    job = Object.new
    job_class = fake_job_class(events:, result: job)

    MarketPrice::RefreshEnqueuer.new(broadcaster:, job_class:).enqueue(
      instrument: instruments(:petr4_bvmf), batch_scope: "batch", batch_run_id: "run"
    )

    state = RefreshStatus::State.read("test_refresh:#{instruments(:petr4_bvmf).id}")
    assert_equal "run", state.run_id
    assert_equal "queued", state.status
  end

  test "passes lease details to a batch job" do
    events = []
    job = Object.new
    job_class = fake_job_class(events:, result: job)

    MarketPrice::RefreshEnqueuer.new(broadcaster: fake_broadcaster(events:), job_class:).enqueue(
      instrument: instruments(:petr4_bvmf), batch_scope: "batch", batch_run_id: "run",
      lease_token: "lease", lease_target: { kind: :current_price, record_id: 1 }
    )

    assert_equal :enqueue, events.last
  end

  test "restores the current state when enqueueing fails" do
    events = []
    broadcaster = fake_broadcaster(events:)
    job_class = fake_job_class(events:, result: false)

    assert_raises(MarketPrice::EnqueueFailure) do
      MarketPrice::RefreshEnqueuer.new(broadcaster:, job_class:).enqueue(
        instrument: instruments(:petr4_bvmf)
      )
    end

    assert_equal %i[ refreshing enqueue current ], events
    assert_equal "failed", RefreshStatus::State.read("test_refresh:#{instruments(:petr4_bvmf).id}").status
  end

  test "does nothing for an unsupported instrument" do
    events = []
    service = Object.new
    service.define_singleton_method(:supports?) { |instrument:| false }

    result = MarketPrice::RefreshEnqueuer.new(
      service:,
      broadcaster: fake_broadcaster(events:),
      job_class: fake_job_class(events:, result: Object.new)
    ).enqueue(instrument: instruments(:voo_arcx))

    assert_nil result
    assert_empty events
  end

  test "enqueues only when the cached quote needs refreshing" do
    service = Object.new
    service.define_singleton_method(:supports?) { |instrument:| true }
    service.define_singleton_method(:read) { |instrument:| CurrentMarketPriceCache::Lookup.new(current_market_price: nil, status: :stale) }
    events = []
    job_class = fake_job_class(events:, result: Object.new)

    MarketPrice::RefreshEnqueuer.new(service:, job_class:).enqueue_if_needed(instrument: instruments(:petr4_bvmf))

    assert_equal [ :enqueue ], events
  end

  test "does not enqueue when a supported quote is fresh" do
    service = Object.new
    service.define_singleton_method(:supports?) { |instrument:| true }
    service.define_singleton_method(:read) { |instrument:| CurrentMarketPriceCache::Lookup.new(current_market_price: nil, status: :fresh) }
    events = []

    MarketPrice::RefreshEnqueuer.new(service:, job_class: fake_job_class(events:, result: Object.new))
      .enqueue_if_needed(instrument: instruments(:petr4_bvmf))

    assert_empty events
  end

  test "does nothing when a supported instrument has no lookup" do
    service = Object.new
    service.define_singleton_method(:supports?) { |instrument:| true }
    service.define_singleton_method(:read) { |instrument:| nil }
    events = []

    MarketPrice::RefreshEnqueuer.new(service:, job_class: fake_job_class(events:, result: Object.new))
      .enqueue_if_needed(instrument: instruments(:petr4_bvmf))

    assert_empty events
  end

  test "does nothing when an instrument is unsupported for conditional refresh" do
    service = Object.new
    service.define_singleton_method(:supports?) { |instrument:| false }
    events = []

    MarketPrice::RefreshEnqueuer.new(service:, job_class: fake_job_class(events:, result: Object.new))
      .enqueue_if_needed(instrument: instruments(:petr4_bvmf))

    assert_empty events
  end

  private

  def fake_broadcaster(events:)
    Object.new.tap do |broadcaster|
      broadcaster.define_singleton_method(:refreshing) { |instrument:| events << :refreshing }
      broadcaster.define_singleton_method(:current) { |instrument:| events << :current }
    end
  end

  def fake_job_class(events:, result:)
    Object.new.tap do |job_class|
      job_class.define_singleton_method(:refresh_scope) { |instrument| "test_refresh:#{instrument.id}" }
      job_class.define_singleton_method(:enqueue_for) do |instrument:, force: false, batch_scope: nil, batch_run_id: nil, **|
        events << :enqueue
        result
      end
    end
  end
end
