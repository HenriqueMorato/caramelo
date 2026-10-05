require "test_helper"

class MarketDataRecoveriesHandlersTest < ActiveSupport::TestCase
  Batch = Struct.new(:scope, :run_id)

  class JobSupportProbe
    include MarketData::Recoveries::JobSupport

    def run(**options, &block)
      run_target(**options, &block)
    end
  end

  setup do
    Rails.cache.clear
    @owner = users(:owner)
    @instrument = instruments(:voo_arcx)
    @batch = Batch.new("batch", "run")
  end

  test "job support releases a supplied lease after completing" do
    target = MarketData::Target.new(kind: :current_price, record_id: @instrument.id)
    released = []
    with_stubbed_method(MarketData::RecoveryLease, :release, ->(**arguments) { released << arguments }) do
      JobSupportProbe.new.run(target_scope: "probe", target_run_id: nil, batch_scope: nil, batch_run_id: nil,
        lease_token: "lease", lease_target: target.to_h) { }
    end

    assert_equal "lease", released.sole.fetch(:token)
  end

  test "queues daily closing price recovery with default range" do
    target = MarketData::Target.new(kind: :daily_closing_prices, record_id: @instrument.id)
    result, enqueued = call_handler(MarketData::Recoveries::DailyClosingPrices, RecoverDailyClosingPricesJob, target:)

    assert result
    assert_equal TradingCalendar.previous_business_day, enqueued.fetch(:from)
    assert_equal TradingCalendar.previous_business_day, enqueued.fetch(:to)
  end

  test "queues daily closing price recovery with explicit range" do
    target = MarketData::Target.new(kind: :daily_closing_prices, record_id: @instrument.id)
    range = Date.new(2026, 8, 1)..Date.new(2026, 8, 3)
    _, enqueued = call_handler(MarketData::Recoveries::DailyClosingPrices, RecoverDailyClosingPricesJob, target:, range:)

    assert_equal range.begin, enqueued.fetch(:from)
    assert_equal range.end, enqueued.fetch(:to)
  end

  test "raises when daily closing price enqueue fails" do
    target = MarketData::Target.new(kind: :daily_closing_prices, record_id: @instrument.id)
    assert_raises(ActiveJob::EnqueueError) do
      call_handler(MarketData::Recoveries::DailyClosingPrices, RecoverDailyClosingPricesJob, target:, result: nil)
    end
  end

  test "queues historical exchange-rate recovery" do
    target = MarketData::Target.new(kind: :historical_exchange_rates, base_currency: "USD", quote_currency: "BRL")
    _, enqueued = call_handler(MarketData::Recoveries::HistoricalExchangeRates, RecoverHistoricalExchangeRatesJob,
      target:, range: Date.new(2026, 8, 1)..Date.new(2026, 8, 3))

    assert_equal "USD", enqueued.fetch(:base_currency)
    assert_equal Date.new(2026, 7, 25), enqueued.fetch(:from)
    assert_equal Date.new(2026, 8, 3), enqueued.fetch(:to)
  end

  test "raises when historical exchange-rate enqueue fails" do
    target = MarketData::Target.new(kind: :historical_exchange_rates, base_currency: "USD", quote_currency: "BRL")
    assert_raises(ActiveJob::EnqueueError) do
      call_handler(MarketData::Recoveries::HistoricalExchangeRates, RecoverHistoricalExchangeRatesJob, target:, result: nil)
    end
  end

  test "queues benchmark observation recovery" do
    benchmark = MarketBenchmark.create!(
      identifier: "HANDLER", name: "Handler benchmark", kind: :price, currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^HANDLER"
    )
    target = MarketData::Target.new(kind: :benchmark_observations, record_id: benchmark.id)
    _, enqueued = call_handler(MarketData::Recoveries::BenchmarkObservations, RecoverBenchmarkObservationsJob,
      target:, range: Date.new(2026, 8, 1)..Date.new(2026, 8, 3))

    assert_equal benchmark.id, enqueued.fetch(:benchmark_id)
    assert_equal Date.new(2026, 8, 3), enqueued.fetch(:to)
  end

  test "raises when benchmark observation enqueue fails" do
    target = MarketData::Target.new(kind: :benchmark_observations, record_id: 1)
    assert_raises(ActiveJob::EnqueueError) do
      call_handler(MarketData::Recoveries::BenchmarkObservations, RecoverBenchmarkObservationsJob, target:, result: nil)
    end
  end

  test "queues a current exchange-rate recovery" do
    target = MarketData::Target.new(kind: :current_exchange_rate, base_currency: "USD", quote_currency: "BRL")
    _, enqueued = call_handler(MarketData::Recoveries::CurrentExchangeRate, RecoverCurrentExchangeRateJob, target:)

    assert_equal "USD", enqueued.fetch(:base_currency)
    assert_equal "BRL", enqueued.fetch(:quote_currency)
  end

  test "raises when current exchange-rate enqueue fails" do
    target = MarketData::Target.new(kind: :current_exchange_rate, base_currency: "USD", quote_currency: "BRL")
    assert_raises(ActiveJob::EnqueueError) do
      call_handler(MarketData::Recoveries::CurrentExchangeRate, RecoverCurrentExchangeRateJob, target:, result: nil)
    end
  end

  test "enqueues current price work without creating a target status" do
    target = MarketData::Target.new(kind: :current_price, record_id: @instrument.id)
    enqueuer = Object.new
    enqueuer.define_singleton_method(:enqueue) { |**| :job }

    result = nil
    with_stubbed_method(MarketPrice::RefreshEnqueuer, :new, -> { enqueuer }) do
      result = MarketData::Recoveries::CurrentPrice.call(
        target:, range: nil, batch_scope: "outer", batch_run_id: "outer-run", owner: @owner
      )
    end

    assert_equal :job, result
  end

  test "advances an active target when current price work is coalesced" do
    target = MarketData::Target.new(kind: :current_price, record_id: @instrument.id)
    state = RefreshStatus::Tracker.enqueue(scope: target.scope, total_count: 1)
    enqueuer = Object.new
    enqueuer.define_singleton_method(:enqueue) { |**| RefreshCurrentMarketPriceJob::COALESCED }
    advanced = nil

    with_stubbed_method(MarketPrice::RefreshEnqueuer, :new, -> { enqueuer }) do
      with_stubbed_method(RefreshStatus::Tracker, :advance, ->(value) { advanced = value }) do
        MarketData::Recoveries::CurrentPrice.call(
          target:, range: nil, batch_scope: "outer", batch_run_id: "outer-run", owner: @owner
        )
      end
    end

    assert_equal state.run_id, advanced.run_id
  end

  test "does not advance a missing current price target state" do
    target = MarketData::Target.new(kind: :current_price, record_id: @instrument.id)
    enqueuer = Object.new
    enqueuer.define_singleton_method(:enqueue) { |**| nil }

    with_stubbed_method(MarketPrice::RefreshEnqueuer, :new, -> { enqueuer }) do
      MarketData::Recoveries::CurrentPrice.call(
        target:, range: nil, batch_scope: "outer", batch_run_id: "outer-run", owner: @owner
      )
    end

    assert_nil RefreshStatus::State.read(target.scope)
  end

  test "queues instrument performance recovery for the requested range" do
    target = MarketData::Target.new(
      kind: :instrument_performance, record_id: @instrument.id, quote_currency: "USD"
    )
    range = Date.new(2026, 8, 12)..Date.new(2026, 8, 14)
    enqueued = nil

    with_stubbed_method(Performance::SeriesRefresh, :enqueue, ->(**attributes) {
      enqueued = attributes
      :queued
    }) do
      result = MarketData::Recoveries::PerformanceObservations.call(
        target:, range:, batch_scope: "outer", batch_run_id: "run", owner: @owner
      )
      assert_equal RefreshCurrentMarketPriceJob::COALESCED, result
    end

    assert_equal @owner, enqueued[:user]
    assert_equal @instrument, enqueued[:instrument]
    assert_equal "USD", enqueued[:reporting_currency]
    assert_equal range.begin, enqueued[:from]
    assert_equal range.end, enqueued[:to]
  end

  test "defaults instrument performance recovery to first trade through today" do
    target = MarketData::Target.new(
      kind: :instrument_performance, record_id: @instrument.id, quote_currency: "BRL"
    )
    enqueued = nil

    with_stubbed_method(Performance::SeriesRefresh, :enqueue, ->(**attributes) {
      enqueued = attributes
      :queued
    }) do
      MarketData::Recoveries::PerformanceObservations.call(
        target:, range: nil, batch_scope: "outer", batch_run_id: "run", owner: @owner
      )
    end

    assert_equal @owner.trades.where(instrument: @instrument).minimum(:traded_on), enqueued[:from]
    assert_equal Date.current, enqueued[:to]
  end

  test "defaults income-only performance recovery to the first income date" do
    owner = User.create!(email_address: "income-recovery@example.com", password: "password")
    instrument = instruments(:voo_arcx)
    performance_on = Date.current - 5.days
    owner.corporate_actions.create!(
      instrument:, kind: :dividend, paid_on: performance_on + 1.day, ex_date: performance_on,
      gross_amount_cents: 1_000, withholding_tax_cents: 0, net_amount_cents: 1_000,
      currency: "USD", source: "manual"
    )
    target = MarketData::Target.new(
      kind: :instrument_performance, record_id: instrument.id, quote_currency: "USD"
    )
    enqueued = nil

    with_stubbed_method(Performance::SeriesRefresh, :enqueue, ->(**attributes) {
      enqueued = attributes
      :queued
    }) do
      MarketData::Recoveries::PerformanceObservations.call(
        target:, range: nil, batch_scope: "outer", batch_run_id: "run", owner:
      )
    end

    assert_equal performance_on, enqueued[:from]
    assert_equal Date.current, enqueued[:to]
  end

  test "defaults portfolio performance recovery to the owner's first trade through today" do
    target = MarketData::Target.new(kind: :portfolio_performance, quote_currency: "BRL")
    enqueued = nil

    with_stubbed_method(Performance::SeriesRefresh, :enqueue, ->(**attributes) {
      enqueued = attributes
      :queued
    }) do
      MarketData::Recoveries::PerformanceObservations.call(
        target:, range: nil, batch_scope: "outer", batch_run_id: "run", owner: @owner
      )
    end

    assert_equal @owner.trades.minimum(:traded_on), enqueued[:from]
    assert_equal Date.current, enqueued[:to]
    assert_not enqueued.key?(:instrument)
  end

  test "queues corporate-action scan recovery for the traded instrument" do
    target = MarketData::Target.new(
      kind: :corporate_action_imports, record_id: @instrument.id,
      provider: CorporateActionImports::Providers::YAHOO_FINANCE
    )
    result = CorporateActionImports::Automation::Result.new(scheduled_count: 1, skipped_count: 0, failed_count: 0)

    with_stubbed_method(CorporateActionImports::Automation, :call, ->(**arguments) {
      assert_equal @owner, arguments.fetch(:user)
      assert_equal @instrument, arguments.fetch(:instrument)
      result
    }) do
      assert_equal RefreshCurrentMarketPriceJob::COALESCED,
        MarketData::Recoveries::CorporateActionImports.call(target:, owner: @owner)
    end
  end

  test "rejects corporate-action recovery for an untraded instrument" do
    target = MarketData::Target.new(kind: :corporate_action_imports, record_id: instruments(:petr4_bvmf).id)

    assert_raises(ActiveRecord::RecordNotFound) do
      MarketData::Recoveries::CorporateActionImports.call(target:, owner: @owner)
    end
  end

  test "raises when corporate-action recovery cannot enqueue a scan" do
    target = MarketData::Target.new(kind: :corporate_action_imports, record_id: @instrument.id)
    result = CorporateActionImports::Automation::Result.new(scheduled_count: 0, skipped_count: 0, failed_count: 1)

    with_stubbed_method(CorporateActionImports::Automation, :call, ->(**) { result }) do
      assert_raises(ActiveJob::EnqueueError) do
        MarketData::Recoveries::CorporateActionImports.call(target:, owner: @owner)
      end
    end
  end

  test "raises when performance recovery enqueue fails" do
    target = MarketData::Target.new(kind: :portfolio_performance, quote_currency: "BRL")

    with_stubbed_method(Performance::SeriesRefresh, :enqueue, ->(**) { :failed }) do
      assert_raises(ActiveJob::EnqueueError) do
        MarketData::Recoveries::PerformanceObservations.call(
          target:, range: Date.current..Date.current, batch_scope: "outer", batch_run_id: "run", owner: @owner
        )
      end
    end
  end

  private

  def call_handler(service, job_class, target:, range: nil, result: :job)
    enqueued = nil
    value = nil
    with_stubbed_method(RefreshStatus::Tracker, :enqueue, ->(**) { @batch }) do
      with_stubbed_method(job_class, :perform_later, ->(**arguments) { enqueued = arguments; result }) do
        value = service.call(target:, range:, batch_scope: "outer", batch_run_id: "outer-run", owner: @owner)
      end
    end
    [ value, enqueued ]
  end

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name) { |*args, **kwargs| replacement.call(*args, **kwargs) }
    yield
  ensure
    object.define_singleton_method(method_name) { |*args, **kwargs| original.call(*args, **kwargs) }
  end
end
