require "test_helper"

class MarketPrice::RefreshEnqueuerTest < ActiveSupport::TestCase
  EnqueuedJob = Data.define(:successfully_enqueued?)

  test "broadcasts refreshing before enqueueing the forced job" do
    events = []
    broadcaster = fake_broadcaster(events:)
    job_class = fake_job_class(events:, successfully_enqueued: true)

    MarketPrice::RefreshEnqueuer.new(broadcaster:, job_class:).enqueue(
      instrument: instruments(:petr4_bvmf)
    )

    assert_equal %i[ refreshing enqueue ], events
  end

  test "restores the current state when enqueueing fails" do
    events = []
    broadcaster = fake_broadcaster(events:)
    job_class = fake_job_class(events:, successfully_enqueued: false)

    assert_raises(ActiveJob::EnqueueError) do
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
      job_class: fake_job_class(events:, successfully_enqueued: true)
    ).enqueue(instrument: instruments(:voo_arcx))

    assert_nil result
    assert_empty events
  end

  private

  def fake_broadcaster(events:)
    Object.new.tap do |broadcaster|
      broadcaster.define_singleton_method(:refreshing) { |instrument:| events << :refreshing }
      broadcaster.define_singleton_method(:current) { |instrument:| events << :current }
    end
  end

  def fake_job_class(events:, successfully_enqueued:)
    Object.new.tap do |job_class|
      job_class.define_singleton_method(:perform_later) do |instrument, force:|
        events << :enqueue
        EnqueuedJob.new(successfully_enqueued)
      end
    end
  end
end
