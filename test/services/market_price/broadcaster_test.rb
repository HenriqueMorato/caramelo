require "test_helper"
require "turbo/broadcastable/test_helper"

class MarketPrice::BroadcasterTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    @instrument = instruments(:petr4_bvmf)
    @entry = CurrentMarketPriceCache::Entry.new(
      current_market_price: nil,
      status: :missing
    )
  end

  test "broadcasts refreshing and current replacements to the instrument stream" do
    service = Object.new
    service.define_singleton_method(:read) { |instrument:| @entry }
    service.instance_variable_set(:@entry, @entry)
    broadcaster = MarketPrice::Broadcaster.new(service:)

    streams = capture_turbo_stream_broadcasts([ MarketPrice::Broadcaster::STREAM_NAME, @instrument ]) do
      broadcaster.refreshing(instrument: @instrument)
      broadcaster.current(instrument: @instrument)
    end

    assert_equal 2, streams.size
    streams.each do |stream|
      assert_equal "replace", stream["action"]
      assert_equal "current_market_price_instrument_#{@instrument.id}", stream["target"]
    end
    assert_includes streams.first.text, "Refreshing"
    assert_not_includes streams.second.text, "Refreshing"
  end
end
