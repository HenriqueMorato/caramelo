require "test_helper"

class HistoricalDataBackfillTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Rails.cache.clear
    clear_enqueued_jobs
  end

  test "creates one pending request and job for an instrument and currency" do
    instrument = instruments(:voo_arcx)

    result = HistoricalDataBackfill.enqueue_for(instrument:, currency: "usd", from_date: Date.new(2026, 8, 1))

    request = HistoricalDataBackfill.sole
    assert_instance_of BackfillHistoricalMarketDataJob, result
    assert_equal instrument, request.instrument
    assert_equal "USD", request.currency
    assert_equal Date.new(2026, 8, 1), request.from_date
    assert_enqueued_with(job: BackfillHistoricalMarketDataJob, args: [ request ])
  end

  test "coalesces repeated requests and retains the earliest date" do
    instrument = instruments(:voo_arcx)
    HistoricalDataBackfill.enqueue_for(instrument:, currency: "USD", from_date: Date.new(2026, 8, 10))

    result = HistoricalDataBackfill.enqueue_for(instrument:, currency: "USD", from_date: Date.new(2026, 8, 1))

    assert_equal HistoricalDataBackfill::COALESCED, result
    assert_equal Date.new(2026, 8, 1), HistoricalDataBackfill.sole.from_date
    assert_equal 2, HistoricalDataBackfill.sole.generation
    assert_enqueued_jobs 1, only: BackfillHistoricalMarketDataJob
  end

  test "does not enqueue a duplicate request with a later date" do
    instrument = instruments(:voo_arcx)
    HistoricalDataBackfill.enqueue_for(instrument:, currency: "USD", from_date: Date.new(2026, 8, 1))

    result = HistoricalDataBackfill.enqueue_for(instrument:, currency: "USD", from_date: Date.new(2026, 8, 10))

    assert_equal HistoricalDataBackfill::COALESCED, result
    assert_equal Date.new(2026, 8, 1), HistoricalDataBackfill.sole.from_date
    assert_equal 1, HistoricalDataBackfill.sole.generation
    assert_enqueued_jobs 1, only: BackfillHistoricalMarketDataJob
  end

  test "removes a newly created request when enqueueing fails" do
    instrument = instruments(:voo_arcx)

    with_stubbed_method(BackfillHistoricalMarketDataJob, :perform_later, ->(*) { nil }) do
      assert_nil HistoricalDataBackfill.enqueue_for(instrument:, currency: "USD", from_date: Date.current)
    end

    assert_empty HistoricalDataBackfill.all
  end

  test "removes a newly created request when enqueueing raises" do
    instrument = instruments(:voo_arcx)
    failure = RuntimeError.new("queue unavailable")

    assert_raises(RuntimeError) do
      with_stubbed_method(BackfillHistoricalMarketDataJob, :perform_later, ->(*) { raise failure }) do
        HistoricalDataBackfill.enqueue_for(instrument:, currency: "USD", from_date: Date.current)
      end
    end

    assert_empty HistoricalDataBackfill.all
  end

  test "preserves a coalescing error when no request was created" do
    failure = RuntimeError.new("database unavailable")

    assert_raises(RuntimeError) do
      with_stubbed_method(HistoricalDataBackfill, :coalesce, ->(**) { raise failure }) do
        HistoricalDataBackfill.enqueue_for(instrument: instruments(:voo_arcx), currency: "USD", from_date: Date.current)
      end
    end
  end

  test "requires the request currency to match its instrument" do
    request = HistoricalDataBackfill.new(instrument: instruments(:petr4_bvmf), currency: "USD", from_date: Date.current)

    assert_not_predicate request, :valid?
    assert_includes request.errors[:currency], "must match the instrument currency"
  end

  test "retries after a concurrent request creation" do
    instrument = instruments(:voo_arcx)
    attempts = 0
    original = HistoricalDataBackfill.method(:find_or_initialize_by)

    with_stubbed_method(HistoricalDataBackfill, :find_or_initialize_by, lambda { |**arguments|
      attempts += 1
      raise ActiveRecord::RecordNotUnique if attempts == 1

      original.call(**arguments)
    }) do
      request, created = HistoricalDataBackfill.coalesce(instrument:, currency: "USD", from_date: Date.current)

      assert_predicate request, :persisted?
      assert created
    end

    assert_equal 2, attempts
  end

  test "only reports pending requests for the requested instruments" do
    instrument = instruments(:voo_arcx)
    HistoricalDataBackfill.create!(instrument:, currency: "USD", from_date: Date.current)

    assert HistoricalDataBackfill.pending_for?(instruments: [ instrument ])

    assert_not HistoricalDataBackfill.pending_for?(instruments: [ instruments(:petr4_bvmf) ])
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    object.singleton_class.define_method(method_name, original)
  end
end
