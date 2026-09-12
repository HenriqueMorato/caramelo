require "test_helper"

class MarketData::PublicationFenceTest < ActiveSupport::TestCase
  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @target = MarketData::Target.new(kind: :daily_closing_prices, record_id: 42)
    @fence = MarketData::PublicationFence.new(target: @target, cache: @cache)
  end

  test "captures and reuses a generation token" do
    generation = @fence.capture

    assert_equal generation, @fence.capture
    assert @cache.exist?(generation_key)
  end

  test "publishes while the generation is current" do
    published = false
    generation = @fence.capture

    result = @fence.publish(generation) { published = true }

    assert_equal :published, result
    assert published
  end

  test "cancels publication after the generation advances" do
    published = false
    generation = @fence.capture
    replacement = @fence.advance { }

    result = @fence.publish(generation) { published = true }

    assert_equal :superseded, result
    refute published
    assert_equal replacement, @fence.capture
  end

  test "advances the generation around reset work" do
    captured = nil
    generation = @fence.advance { |value| captured = value }

    assert_equal captured, generation
    assert_equal generation, @fence.capture
  end

  test "waits for and then releases another worker's lock" do
    @cache.write(lock_key, "other-worker")
    sleeps = []
    fence = MarketData::PublicationFence.new(
      target: @target,
      cache: @cache,
      sleeper: ->(duration) { sleeps << duration; @cache.delete(lock_key) }
    )

    fence.advance { }

    assert_equal [ 0.05 ], sleeps
    refute @cache.exist?(lock_key)
  end

  test "does not release another worker's lock" do
    @cache.write(lock_key, "other-worker")

    @fence.send(:release_lock, "this-worker")

    assert_equal "other-worker", @cache.read(lock_key)
  end

  private

  def generation_key
    "caramelo:market_data:generation:#{@target.scope}"
  end

  def lock_key
    "#{generation_key}:lock"
  end
end
