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

  test "only reports pending requests for the owner's instruments" do
    instrument = instruments(:voo_arcx)
    HistoricalDataBackfill.create!(instrument:, currency: "USD", from_date: Date.current)

    assert HistoricalDataBackfill.pending_for?

    Trade.where(user: users(:owner)).delete_all

    assert_not HistoricalDataBackfill.pending_for?
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
