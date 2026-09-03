require "test_helper"

class MarketPrice::ManualRefreshTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
  end

  test "returns false while the manual cooldown is active" do
    Rails.cache.write(MarketPrice::ManualRefresh::COOLDOWN_KEY, Time.current)

    refresh = MarketPrice::ManualRefresh.new(enqueuer: fake_enqueuer)

    assert_not refresh.call
  end

  test "advances a batch when an instrument refresh is coalesced" do
    instrument = instruments(:petr4_bvmf)
    User.owner.trades.create!(instrument:, side: :buy, traded_on: Date.current, quantity: 1, unit_price: 10,
      fees_cents: 0, currency: instrument.currency)
    refresh = MarketPrice::ManualRefresh.new(enqueuer: fake_enqueuer(result: RefreshCurrentMarketPriceJob::COALESCED))

    assert refresh.call
    assert_equal "succeeded", RefreshStatus::State.read(MarketPrice::ManualRefresh::REFRESH_SCOPE).status
  end

  test "does not advance when the batch state has disappeared" do
    instrument = instruments(:petr4_bvmf)
    User.owner.trades.create!(instrument:, side: :buy, traded_on: Date.current, quantity: 1, unit_price: 10,
      fees_cents: 0, currency: instrument.currency)
    refresh = MarketPrice::ManualRefresh.new(enqueuer: fake_enqueuer(result: nil))

    batch = Struct.new(:run_id).new("test-run")
    with_stubbed_method(RefreshStatus::Tracker, :enqueue, ->(**) { batch }) do
      with_stubbed_method(RefreshStatus::State, :read, ->(*) { nil }) do
        assert refresh.call
      end
    end
  end

  private

  def fake_enqueuer(result: Object.new)
    Object.new.tap do |enqueuer|
      enqueuer.define_singleton_method(:enqueue) { |**| result }
    end
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, &replacement)
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end
end
