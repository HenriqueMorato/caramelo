require "test_helper"

class MarketData::RecoveryTest < ActiveSupport::TestCase
  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @target = MarketData::Target.new(kind: :current_price, record_id: instruments(:voo_arcx).id)
    @calls = []
    @handler = lambda do |**arguments|
      @calls << arguments
    end
  end

  test "queues a supported target in a refresh batch" do
    result = MarketData::Recovery.call(
      target: @target, cache: @cache, handlers: { current_price: @handler }
    )

    assert_predicate result, :queued?
    assert_equal @target, result.target
    assert_equal 1, @calls.size
    assert_equal result.batch_run_id, @calls.first.fetch(:batch_run_id)
    assert_equal @target, @calls.first.fetch(:target)
  end

  test "broadcasts health after queueing work" do
    broadcasts = 0
    with_stubbed_method(MarketData::HealthReportBroadcaster, :refresh, -> { broadcasts += 1 }) do
      result = MarketData::Recovery.call(
        target: @target, cache: @cache, handlers: { current_price: @handler }
      )

      assert_predicate result, :queued?
    end

    assert_equal 1, broadcasts
  end

  test "broadcasts health after coalesced work is completed" do
    broadcasts = 0
    handler = ->(**) { RefreshCurrentMarketPriceJob::COALESCED }

    with_stubbed_method(MarketData::HealthReportBroadcaster, :refresh, -> { broadcasts += 1 }) do
      result = MarketData::Recovery.call(target: @target, cache: @cache, handlers: { current_price: handler })

      assert_predicate result, :queued?
    end

    assert_equal 1, broadcasts
  end

  test "keeps recovery successful when the health broadcast fails" do
    broadcast_error = RuntimeError.new("broadcast unavailable")
    reported = []

    with_stubbed_method(MarketData::HealthReportBroadcaster, :refresh, -> { raise broadcast_error }) do
      with_stubbed_method(Rails.error, :report, ->(error, **) { reported << error }) do
        result = MarketData::Recovery.call(
          target: @target, cache: @cache, handlers: { current_price: @handler }
        )

        assert_predicate result, :queued?
      end
    end

    assert_equal [ broadcast_error ], reported
  end

  test "advances the publication fence before replacement work is enqueued" do
    fence = MarketData::PublicationFence.new(target: @target, cache: @cache)
    previous_generation = fence.capture
    generation_during_enqueue = nil
    handler = lambda do |**|
      generation_during_enqueue = fence.capture
      :queued
    end

    result = MarketData::Recovery.call(
      target: @target, cache: @cache, handlers: { current_price: handler }, replacement: true
    )

    assert_predicate result, :queued?
    refute_equal previous_generation, generation_during_enqueue
    assert_equal generation_during_enqueue, fence.capture
  end

  test "throttles a repeated target" do
    handlers = { current_price: @handler }
    MarketData::Recovery.call(target: @target, cache: @cache, handlers:)

    result = MarketData::Recovery.call(target: @target, cache: @cache, handlers:)

    assert_predicate result, :already_running?
    assert_equal 1, @calls.size
    refute MarketData::Recovery.available?(target: @target, cache: @cache)
  end

  test "returns unsupported for a target without a handler" do
    target = MarketData::Target.new(kind: :benchmark_observations, record_id: 2)

    result = MarketData::Recovery.call(target:, cache: @cache, handlers: {})

    assert_predicate result, :unsupported?
    assert_empty @calls
  end

  test "returns unsupported when a handler cannot enqueue work" do
    handler = ->(**) { nil }

    result = MarketData::Recovery.call(
      target: @target, cache: @cache, handlers: { current_price: handler }
    )

    assert_predicate result, :unsupported?
    assert_equal "succeeded", RefreshStatus::State.read(result.batch_scope).status
    assert MarketData::Recovery.available?(target: @target, cache: @cache)
  end

  test "returns throttled and releases its lease when cooldown is taken" do
    cache = ActiveSupport::Cache::MemoryStore.new
    cache.write(MarketData::Recovery.cooldown_key(@target), "other-worker")

    result = MarketData::Recovery.call(
      target: @target, cache:, handlers: { current_price: @handler }
    )

    assert_predicate result, :throttled?
    assert_nil MarketData::RecoveryLease.current(target: @target, cache:)
  end

  test "does not release a cooldown without its owner token" do
    service = MarketData::Recovery.new(target: @target, range: nil, owner: users(:owner), cache: @cache,
      handlers: { current_price: @handler })
    assert_nil service.send(:release_cooldown, nil)
  end

  test "does not release a lease when lease acquisition itself fails" do
    failure = RuntimeError.new("lease backend unavailable")

    assert_raises(RuntimeError) do
      with_stubbed_method(MarketData::RecoveryLease, :acquire, ->(**) { raise failure }) do
        MarketData::Recovery.call(target: @target, cache: @cache, handlers: { current_price: @handler })
      end
    end
  end

  test "handles an exception while reporting an already-running lease" do
    failure = RuntimeError.new("result failed")
    service = MarketData::Recovery.new(target: @target, range: nil, owner: users(:owner), cache: @cache,
      handlers: { current_price: @handler })
    service.define_singleton_method(:result) { |*| raise failure }

    assert_raises(RuntimeError) do
      with_stubbed_method(MarketData::RecoveryLease, :acquire, ->(**) { nil }) { service.call }
    end
  end

  test "completes the batch when current-price work is coalesced" do
    handler = ->(**) { RefreshCurrentMarketPriceJob::COALESCED }

    result = MarketData::Recovery.call(
      target: @target, cache: @cache, handlers: { current_price: handler }
    )

    assert_predicate result, :queued?
    assert_equal "succeeded", RefreshStatus::State.read(result.batch_scope).status
  end

  test "releases cooldown and records batch failure when a handler raises" do
    failure = RuntimeError.new("queue unavailable")
    batch_scope = nil
    handler = lambda do |**arguments|
      batch_scope = arguments.fetch(:batch_scope)
      raise failure
    end

    assert_raises(RuntimeError) do
      MarketData::Recovery.call(
        target: @target, cache: @cache, handlers: { current_price: handler }
      )
    end

    assert MarketData::Recovery.available?(target: @target, cache: @cache)
    state = RefreshStatus::State.read(batch_scope)
    assert_predicate state, :failed?
    assert_equal "queue unavailable", state.error_message
  end

  test "raises when batch creation fails before a batch exists" do
    failure = RuntimeError.new("batch unavailable")
    cache = ActiveSupport::Cache::MemoryStore.new

    assert_raises(RuntimeError) do
      with_stubbed_method(RefreshStatus::Tracker, :enqueue, ->(**) { raise failure }) do
        MarketData::Recovery.call(target: @target, cache:, handlers: { current_price: @handler })
      end
    end
  end

  test "does not delete a cooldown owned by another request" do
    cache = ActiveSupport::Cache::MemoryStore.new
    handler = ->(**) { raise "queue unavailable" }
    cache.define_singleton_method(:read) { |_key| "another-token" }

    assert_raises(RuntimeError) do
      MarketData::Recovery.call(target: @target, cache:, handlers: { current_price: handler })
    end
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name) { |*args, **kwargs| replacement.call(*args, **kwargs) }
    yield
  ensure
    object.define_singleton_method(method_name) { |*args, **kwargs| original.call(*args, **kwargs) }
  end
end
