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
      result = MarketData::Reset.call(target: @target, preview_token:, cache: @cache)
    end

    assert_predicate result, :queued?
    assert_predicate cache.read(instrument: @instrument, provider: "yahoo_finance"), :fresh?
  end

  test "passes the recovery lease to the replacement job" do
    arguments = nil
    enqueuer = Object.new
    enqueuer.define_singleton_method(:enqueue) { |**kwargs| arguments = kwargs; :queued_job }

    with_stubbed_method(MarketPrice::RefreshEnqueuer, :new, -> { enqueuer }) do
      result = MarketData::Reset.call(target: @target, preview_token:, cache: @cache)
      assert_predicate result, :queued?
    end

    assert arguments[:lease_token].present?
    assert_equal @target.to_h, arguments[:lease_target]
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
    target = Struct.new(:kind).new(:unsupported)

    assert_predicate MarketData::Reset.call(target:, cache: @cache), :unsupported?
  end

  test "deletes only instrument derived rows and advances its generation before rebuilding" do
    owner = users(:owner)
    date = Date.new(2026, 8, 12)
    materialization = InstrumentPerformanceMaterialization.for(
      user: owner, instrument: @instrument, reporting_currency: "USD"
    )
    observation = InstrumentPerformanceObservation.create!(
      user: owner, instrument: @instrument, reporting_currency: "USD", observed_on: date,
      status: :available, source_generation: materialization.source_generation, generated_at: Time.current,
      market_value_amount: "100", cost_basis_amount: "90", realized_gain_amount: "1",
      unrealized_gain_amount: "9", net_cash_flow_amount: "-90"
    )
    target = MarketData::Target.new(
      kind: :instrument_performance, record_id: @instrument.id, quote_currency: "USD"
    )
    preview = MarketData::ResetPreview.create(target:, owner:, range: date..date)
    source_counts = [ owner.trades.count, DailyClosingPrice.count, HistoricalExchangeRate.count ]
    enqueued = nil

    with_stubbed_method(Performance::SeriesRefresh, :enqueue, ->(**attributes) {
      enqueued = attributes
      :queued
    }) do
      result = MarketData::Reset.call(target:, preview_token: preview.token, owner:, cache: @cache)
      assert_predicate result, :queued?
    end

    refute InstrumentPerformanceObservation.exists?(observation.id)
    assert_equal source_counts, [ owner.trades.count, DailyClosingPrice.count, HistoricalExchangeRate.count ]
    assert_equal 1, materialization.reload.source_generation
    assert_equal date..date, materialization.requested_range
    assert_equal @instrument, enqueued[:instrument]
    assert_equal "USD", enqueued[:reporting_currency]
  end

  test "rejects an instrument performance reset outside the owner scope" do
    instrument = instruments(:petr4_bvmf)
    target = MarketData::Target.new(
      kind: :instrument_performance, record_id: instrument.id, quote_currency: instrument.currency
    )
    preview = MarketData::ResetPreview.create(target:, owner: users(:owner))

    assert_raises(ActiveRecord::RecordNotFound) do
      MarketData::Reset.call(target:, preview_token: preview.token, cache: @cache)
    end
  end

  test "reuses the verified preview range for historical recovery targets" do
    target = MarketData::Target.new(kind: :daily_closing_prices, record_id: @instrument.id,
      provider: "yahoo_finance")
    range = Date.new(2026, 8, 24)..Date.new(2026, 8, 28)
    preview = Struct.new(:range).new(range)
    recovery = Struct.new(:status).new(:queued)
    received = nil

    with_stubbed_method(MarketData::ResetPreview, :verify, ->(**) { preview }) do
      with_stubbed_method(MarketData::Recovery, :call, ->(**kwargs) { received = kwargs; recovery }) do
        result = MarketData::Reset.call(target:, preview_token: "signed", cache: @cache)
        assert_predicate result, :queued?
      end
    end

    assert_equal range, received[:range]
    assert_equal target, received[:target]
  end

  test "requires a signed preview for supported targets" do
    assert_raises(ArgumentError, "reset preview is required") do
      MarketData::Reset.call(target: @target, cache: @cache)
    end
  end

  test "rejects an instrument outside the owner scope" do
    target = MarketData::Target.new(kind: :current_price, record_id: instruments(:petr4_bvmf).id,
      provider: "yahoo_finance")

    assert_raises(ActiveRecord::RecordNotFound) do
      MarketData::Reset.call(target:, preview_token: MarketData::ResetPreview.create(target:).token, cache: @cache)
    end
  end

  test "does not clear a quote while its refresh is active" do
    RefreshStatus::Tracker.enqueue(scope: @target.scope, total_count: 1)

    assert_predicate MarketData::Reset.call(target: @target, preview_token:, cache: @cache), :busy?
  end

  test "reports busy when another recovery lease owns the quote" do
    with_stubbed_method(MarketData::RecoveryLease, :acquire, ->(**) { nil }) do
      assert_predicate MarketData::Reset.call(target: @target, preview_token:, cache: @cache), :busy?
    end
  end

  test "reports unsupported when replacement enqueue returns nil" do
    enqueuer = Object.new
    enqueuer.define_singleton_method(:enqueue) { |**| nil }

    result = nil
    with_stubbed_method(MarketPrice::RefreshEnqueuer, :new, -> { enqueuer }) do
      result = MarketData::Reset.call(target: @target, preview_token:, cache: @cache)
    end

    assert_predicate result, :unsupported?
    assert_nil MarketData::RecoveryLease.current(target: @target, cache: @cache)
  end

  test "releases the recovery lease when enqueue raises" do
    failure = RuntimeError.new("queue unavailable")
    enqueuer = Object.new
    enqueuer.define_singleton_method(:enqueue) { |**| raise failure }

    assert_raises(RuntimeError) do
      with_stubbed_method(MarketPrice::RefreshEnqueuer, :new, -> { enqueuer }) do
        MarketData::Reset.call(target: @target, preview_token:, cache: @cache)
      end
    end

    assert_nil MarketData::RecoveryLease.current(target: @target, cache: @cache)
  end

  private

  def preview_token
    MarketData::ResetPreview.create(target: @target).token
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name) { |*args, **kwargs| replacement.call(*args, **kwargs) }
    yield
  ensure
    object.define_singleton_method(method_name) { |*args, **kwargs| original.call(*args, **kwargs) }
  end
end
