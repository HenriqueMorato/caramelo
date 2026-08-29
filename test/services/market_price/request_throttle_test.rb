require "test_helper"

class MarketPrice::RequestThrottleTest < ActiveSupport::TestCase
  test "waits only for the remaining provider interval" do
    cache = ActiveSupport::Cache::MemoryStore.new
    now = Time.utc(2026, 8, 28, 15)
    sleeps = []
    sleeper = ->(duration) { sleeps << duration; now += duration }
    throttle = MarketPrice::RequestThrottle.new(cache:, interval: 1.second, clock: -> { now }, sleeper:)

    throttle.wait!
    now += 0.25
    throttle.wait!

    assert_equal [ 0.75 ], sleeps
    assert_in_delta now.to_f, cache.read(MarketPrice::RequestThrottle::CACHE_KEY).to_f, 0.001
  end

  test "does not sleep when the previous request is outside the interval" do
    cache = ActiveSupport::Cache::MemoryStore.new
    now = Time.utc(2026, 8, 28, 15)
    sleeps = []
    throttle = MarketPrice::RequestThrottle.new(cache:, interval: 1.second, clock: -> { now }, sleeper: ->(duration) { sleeps << duration })

    throttle.wait!
    now += 2.seconds
    throttle.wait!

    assert_empty sleeps
  end

  test "rejects a negative interval" do
    assert_raises(ArgumentError) { MarketPrice::RequestThrottle.new(interval: -1.second) }
  end

  test "rejects an invalid configured interval" do
    previous = ENV["YAHOO_FINANCE_MINIMUM_INTERVAL_SECONDS"]
    %w[not-a-number 0].each do |value|
      ENV["YAHOO_FINANCE_MINIMUM_INTERVAL_SECONDS"] = value

      assert_raises(ArgumentError) { MarketPrice::RequestThrottle.new }
    end
  ensure
    ENV["YAHOO_FINANCE_MINIMUM_INTERVAL_SECONDS"] = previous
  end

  test "includes the instrument in throttle notifications" do
    cache = ActiveSupport::Cache::MemoryStore.new
    now = Time.utc(2026, 8, 28, 15)
    instrument = instruments(:petr4_bvmf)
    throttle = MarketPrice::RequestThrottle.new(cache:, interval: 1.second, clock: -> { now }, sleeper: ->(*) { })
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("market_price.refresh") do |_name, _start, _finish, _id, payload|
      events << payload
    end

    throttle.wait!(instrument:)
    now += 0.25
    throttle.wait!(instrument:)

    assert_equal instrument.id, events.sole.fetch(:instrument_id)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
