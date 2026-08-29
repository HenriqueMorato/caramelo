require "test_helper"

class MarketData::YahooFinance::RequestThrottleTest < ActiveSupport::TestCase
  test "generic throttle scopes cache and notifications by provider" do
    cache = ActiveSupport::Cache::MemoryStore.new
    throttle = MarketData::RequestThrottle.new(provider: "other_feed", interval: 0.seconds, cache:)

    throttle.wait!

    assert cache.exist?("localfolio:market_data:other_feed:last_request_at")
  end

  test "requires a provider scope" do
    assert_raises(ArgumentError) { MarketData::RequestThrottle.new(provider: "", interval: 1.second) }
  end

  test "waits for another worker to release the provider lock" do
    cache = ActiveSupport::Cache::MemoryStore.new
    cache.write("localfolio:market_data:other_feed:last_request_at:lock", "other-worker")
    sleeps = []
    sleeper = lambda do |duration|
      sleeps << duration
      cache.delete("localfolio:market_data:other_feed:last_request_at:lock")
    end
    throttle = MarketData::RequestThrottle.new(provider: "other_feed", interval: 0.seconds, cache:, sleeper:)

    throttle.wait!

    assert_equal [ 0.05 ], sleeps
  end

  test "does not release another worker's lock" do
    cache = ActiveSupport::Cache::MemoryStore.new
    cache.write("localfolio:market_data:other_feed:last_request_at:lock", "other-worker")
    throttle = MarketData::RequestThrottle.new(provider: "other_feed", interval: 0.seconds, cache:)

    throttle.send(:release_lock, "this-worker")

    assert_equal "other-worker", cache.read("localfolio:market_data:other_feed:last_request_at:lock")
  end

  test "waits only for the remaining provider interval" do
    cache = ActiveSupport::Cache::MemoryStore.new
    now = Time.utc(2026, 8, 28, 15)
    sleeps = []
    sleeper = ->(duration) { sleeps << duration; now += duration }
    throttle = MarketData::YahooFinance::RequestThrottle.new(cache:, interval: 1.second, clock: -> { now }, sleeper:)

    throttle.wait!
    now += 0.25
    throttle.wait!

    assert_equal [ 0.75 ], sleeps
    assert_in_delta now.to_f, cache.read("localfolio:market_data:yahoo_finance:last_request_at").to_f, 0.001
  end

  test "does not sleep when the previous request is outside the interval" do
    cache = ActiveSupport::Cache::MemoryStore.new
    now = Time.utc(2026, 8, 28, 15)
    sleeps = []
    throttle = MarketData::YahooFinance::RequestThrottle.new(cache:, interval: 1.second, clock: -> { now }, sleeper: ->(duration) { sleeps << duration })

    throttle.wait!
    now += 2.seconds
    throttle.wait!

    assert_empty sleeps
  end

  test "rejects a negative interval" do
    assert_raises(ArgumentError) { MarketData::YahooFinance::RequestThrottle.new(interval: -1.second) }
  end

  test "rejects an invalid configured interval" do
    previous = ENV["YAHOO_FINANCE_MINIMUM_INTERVAL_SECONDS"]
    %w[not-a-number 0].each do |value|
      ENV["YAHOO_FINANCE_MINIMUM_INTERVAL_SECONDS"] = value

      assert_raises(ArgumentError) { MarketData::YahooFinance::RequestThrottle.new }
    end
  ensure
    ENV["YAHOO_FINANCE_MINIMUM_INTERVAL_SECONDS"] = previous
  end

  test "includes the instrument in throttle notifications" do
    cache = ActiveSupport::Cache::MemoryStore.new
    now = Time.utc(2026, 8, 28, 15)
    instrument = instruments(:petr4_bvmf)
    throttle = MarketData::YahooFinance::RequestThrottle.new(cache:, interval: 1.second, clock: -> { now }, sleeper: ->(*) { })
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("market_data.yahoo_finance.request") do |_name, _start, _finish, _id, payload|
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
