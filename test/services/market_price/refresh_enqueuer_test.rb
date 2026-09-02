require "test_helper"

class MarketPrice::RefreshEnqueuerTest < ActiveSupport::TestCase
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
      job_class.define_singleton_method(:enqueue_for) do |instrument:, force: false|
        events << :enqueue
        result
      end
    end
  end
end
