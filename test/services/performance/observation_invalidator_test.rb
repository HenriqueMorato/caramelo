require "test_helper"

class Performance::ObservationInvalidatorTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    @user = users(:owner)
    @from = Date.new(2026, 8, 20)
    @store = RecordingStore.new
    @refresher = RecordingRefresher.new
  end

  test "marks affected dates stale and enqueues a rebuild" do
    invalidator.mark!
    result = invalidator.enqueue

    assert_equal :queued, result
    assert_equal [ @from ], @store.stale_dates
    assert_equal [ [ @user, @from, Date.current ] ], @refresher.requests
  end

  test "can invalidate without enqueueing during a larger batch" do
    result = invalidator.mark!

    assert_equal :stale, result
    assert_equal [ @from ], @store.stale_dates
    assert_empty @refresher.requests
  end

  test "clears derived observations after the last trade is removed" do
    Trade.where(user: @user).delete_all

    assert_equal :cleared, invalidator.mark!
    assert_equal 1, @store.delete_count
  end

  test "ignores a future invalidation boundary" do
    result = invalidator(from: Date.current + 1).mark!

    assert_equal :future, result
    assert_equal :future, invalidator(from: Date.current + 1).enqueue
    assert_empty @store.stale_dates
  end

  test "propagates dirty marker failures so the source transaction can roll back" do
    @store.error = RuntimeError.new("dirty marker failed")

    error = assert_raises(RuntimeError) { invalidator.mark! }

    assert_equal "dirty marker failed", error.message
  end

  test "reports enqueue failures without breaking committed source persistence" do
    @refresher.error = RuntimeError.new("queue unavailable")
    reported = []

    with_stubbed_method(Rails.error, :report, ->(error, **) { reported << error }) do
      assert_equal :failed, invalidator.enqueue
    end

    assert_equal "queue unavailable", reported.first.message
  end

  test "maintains native reporting and existing instrument currency views" do
    instrument = instruments(:voo_arcx)
    InstrumentPerformanceMaterialization.for(user: @user, instrument:, reporting_currency: "EUR")

    Performance::ObservationInvalidator.mark_instrument!(user: @user, instrument:, from: @from)
    Performance::ObservationInvalidator.enqueue_instrument(user: @user, instrument:, from: @from)

    materializations = @user.instrument_performance_materializations.where(instrument:).index_by(&:reporting_currency)
    assert_equal %w[BRL EUR USD], materializations.keys.sort
    assert materializations.values.all? { |item| item.source_generation == 1 && item.requested_from == @from }
    assert_enqueued_jobs 3, only: BuildInstrumentPerformanceObservationsJob
  end

  test "can invalidate only one affected instrument currency view" do
    instrument = instruments(:voo_arcx)

    Performance::ObservationInvalidator.mark_instrument!(
      user: @user, instrument:, from: @from, reporting_currency: "BRL"
    )

    materializations = @user.instrument_performance_materializations.where(instrument:)
    assert_equal [ "BRL" ], materializations.pluck(:reporting_currency)
  end

  private

  def invalidator(from: @from)
    Performance::ObservationInvalidator.new(
      user: @user, from:, store: @store, refresher: @refresher
    )
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end

  class RecordingStore
    attr_accessor :error
    attr_reader :stale_dates, :delete_count

    def initialize
      @stale_dates = []
      @delete_count = 0
    end

    def stale_from(date)
      raise error if error

      stale_dates << date
    end

    def delete_all
      @delete_count += 1
    end
  end

  class RecordingRefresher
    attr_accessor :error
    attr_reader :requests

    def initialize
      @requests = []
    end

    def enqueue(user:, from:, to:, reporting_currency:, instrument: nil)
      raise error if error

      requests << [ user, from, to ]
      :queued
    end
  end
end
