require "test_helper"

class MarketData::ResetTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @cache = ActiveSupport::Cache::MemoryStore.new
    @instrument = instruments(:voo_arcx)
    @target = MarketData::Target.new(
      kind: :current_price, record_id: @instrument.id, provider: "yahoo_finance"
    )
  end

  test "queues a fenced replacement for a traded instrument quote" do
    cache = CurrentMarketPriceCache.new(cache: @cache)
    quote = CurrentMarketPrice.new(
      unit_price: "123.45", currency: @instrument.currency, provider: "yahoo_finance",
      quoted_at: Time.current, fetched_at: Time.current
    )
    cache.write(instrument: @instrument, current_market_price: quote)

    enqueuer = Object.new
    enqueuer.define_singleton_method(:enqueue) { |**| :queued_job }

    result = nil
    with_stubbed_method(MarketPrice::RefreshEnqueuer, :new, -> { enqueuer }) do
      result = MarketData::Reset.call(target: @target, cache: @cache)
    end

    assert_predicate result, :queued?
    assert_predicate cache.read(instrument: @instrument, provider: "yahoo_finance"), :fresh?
  end

  test "verifies a supplied reset preview token" do
    verified = false
    with_stubbed_method(MarketData::ResetPreview, :verify, ->(**) { verified = true }) do
      enqueuer = Object.new
      enqueuer.define_singleton_method(:enqueue) { |**| :queued_job }
      with_stubbed_method(MarketPrice::RefreshEnqueuer, :new, -> { enqueuer }) do
        result = MarketData::Reset.call(target: @target, preview_token: "signed", cache: @cache)
        assert_predicate result, :queued?
      end
    end

    assert verified
  end

  test "does not clear unsupported target kinds" do
    target = MarketData::Target.new(kind: :daily_closing_prices, record_id: @instrument.id)

    assert_predicate MarketData::Reset.call(target:, cache: @cache), :unsupported?
  end

  test "rejects an instrument outside the owner scope" do
    target = MarketData::Target.new(kind: :current_price, record_id: instruments(:petr4_bvmf).id)

    assert_raises(ActiveRecord::RecordNotFound) do
      MarketData::Reset.call(target:, cache: @cache)
    end
  end

  test "does not clear a quote while its refresh is active" do
    RefreshStatus::Tracker.enqueue(scope: @target.scope, total_count: 1)

    assert_predicate MarketData::Reset.call(target: @target, cache: @cache), :busy?
  end

  test "reports unsupported when replacement enqueue returns nil" do
    enqueuer = Object.new
    enqueuer.define_singleton_method(:enqueue) { |**| nil }

    result = nil
    with_stubbed_method(MarketPrice::RefreshEnqueuer, :new, -> { enqueuer }) do
      result = MarketData::Reset.call(target: @target, cache: @cache)
    end

    assert_predicate result, :unsupported?
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
