require "test_helper"

class MarketDataRecoveryJobsTest < ActiveJob::TestCase
  setup do
    Rails.cache.clear
    @batch = RefreshStatus::Tracker.enqueue(scope: "test_recovery_batch", total_count: 1)
    @waiter = Object.new
    @waiter.define_singleton_method(:wait!) { |**| }
  end

  test "recovers a current exchange rate" do
    calls = []
    service = Object.new
    service.define_singleton_method(:refresh) { |**arguments| calls << arguments }
    target_scope = "market_data_health:current_exchange_rate:USD:BRL:yahoo_finance_fx"
    target = RefreshStatus::Tracker.enqueue(scope: target_scope, total_count: 1)

    with_stubbed_method(MarketData::YahooFinance::RequestThrottle, :new, ->(**) { @waiter }) do
      with_stubbed_method(ExchangeRate::Service, :default, -> { service }) do
        RecoverCurrentExchangeRateJob.perform_now(
          base_currency: "USD", quote_currency: "BRL", target_scope:, target_run_id: target.run_id,
          batch_scope: @batch.scope, batch_run_id: @batch.run_id
        )
      end
    end

    assert_equal [ { base_currency: "USD", quote_currency: "BRL", force: true } ], calls
    assert_equal "succeeded", RefreshStatus::State.read(target_scope).status
    assert_equal "succeeded", RefreshStatus::State.read(@batch.scope).status
  end

  test "recovers daily closing prices" do
    calls = []
    importer = Object.new
    importer.define_singleton_method(:call) { |**arguments| calls << arguments }
    target = RefreshStatus::Tracker.enqueue(scope: "market_data_health:daily_closing_prices:1:yahoo_finance", total_count: 1)

    with_stubbed_method(MarketData::YahooFinance::RequestThrottle, :new, ->(**) { @waiter }) do
      with_stubbed_method(DailyClosingPrice::Importer, :default, -> { importer }) do
        RecoverDailyClosingPricesJob.perform_now(
          instrument_id: instruments(:voo_arcx).id,
          from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 2), target_scope: target.scope,
          target_run_id: target.run_id, batch_scope: @batch.scope, batch_run_id: @batch.run_id
        )
      end
    end

    assert_equal Date.new(2026, 8, 1), calls.sole.fetch(:from)
    assert_equal Date.new(2026, 8, 2), calls.sole.fetch(:to)
    assert_equal true, calls.sole.fetch(:enqueue_performance_rebuild)
  end

  test "recovers historical exchange rates" do
    calls = []
    importer = Object.new
    importer.define_singleton_method(:call) { |**arguments| calls << arguments }
    target = RefreshStatus::Tracker.enqueue(scope: "market_data_health:historical_exchange_rates:USD:BRL:yahoo_finance_fx", total_count: 1)

    with_stubbed_method(MarketData::YahooFinance::RequestThrottle, :new, ->(**) { @waiter }) do
      with_stubbed_method(HistoricalExchangeRate::Importer, :default, -> { importer }) do
        RecoverHistoricalExchangeRatesJob.perform_now(
          base_currency: "USD", quote_currency: "BRL", from: Date.new(2026, 8, 1),
          to: Date.new(2026, 8, 2), target_scope: target.scope, target_run_id: target.run_id,
          batch_scope: @batch.scope, batch_run_id: @batch.run_id
        )
      end
    end

    assert_equal "USD", calls.sole.fetch(:base_currency)
    assert_equal true, calls.sole.fetch(:enqueue_performance_rebuild)
  end

  test "recovers supported benchmark observations" do
    calls = []
    importer = Object.new
    importer.define_singleton_method(:supports?) { |benchmark:| true }
    importer.define_singleton_method(:call) { |**arguments| calls << arguments }
    benchmark = MarketBenchmark.create!(identifier: "RECOVER", name: "Recovery", kind: :price, currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^RECOVER")
    target = RefreshStatus::Tracker.enqueue(scope: "market_data_health:benchmark_observations:#{benchmark.id}:yahoo_finance", total_count: 1)

    with_stubbed_method(MarketData::YahooFinance::RequestThrottle, :new, ->(**) { @waiter }) do
      with_stubbed_method(MarketBenchmark::Importer, :default, -> { importer }) do
        RecoverBenchmarkObservationsJob.perform_now(
          benchmark_id: benchmark.id, from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 2),
          target_scope: target.scope, target_run_id: target.run_id,
          batch_scope: @batch.scope, batch_run_id: @batch.run_id
        )
      end
    end

    assert_equal benchmark, calls.sole.fetch(:benchmark)
    assert_equal Date.new(2026, 8, 1), calls.sole.fetch(:from)
  end

  test "fails unsupported benchmark providers" do
    benchmark = MarketBenchmark.create!(identifier: "UNSUPPORTED", name: "Unsupported", kind: :price,
      currency: "USD", provider: "other", provider_identifier: "^UNSUPPORTED")
    target = RefreshStatus::Tracker.enqueue(scope: "unsupported_benchmark", total_count: 1)
    importer = Object.new
    importer.define_singleton_method(:supports?) { |benchmark:| false }

    with_stubbed_method(MarketBenchmark::Importer, :default, -> { importer }) do
      RecoverBenchmarkObservationsJob.perform_now(
        benchmark_id: benchmark.id, from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 2),
        target_scope: target.scope, target_run_id: target.run_id, batch_scope: @batch.scope,
        batch_run_id: @batch.run_id
      )
    end

    assert_predicate RefreshStatus::State.read(target.scope), :failed?
  end

  test "records a failed target and batch when recovery raises" do
    failure = RuntimeError.new("provider unavailable")
    calls = []
    importer = Object.new
    importer.define_singleton_method(:call) { |**| calls << true; raise failure }
    target = RefreshStatus::Tracker.enqueue(scope: "test_failed_daily_closing_prices", total_count: 1)
    assert_equal target.run_id, RefreshStatus::State.read(target.scope).run_id

    with_stubbed_method(MarketData::YahooFinance::RequestThrottle, :new, ->(**) { @waiter }) do
      with_stubbed_method(DailyClosingPrice::Importer, :default, -> { importer }) do
        RecoverDailyClosingPricesJob.perform_now(
          instrument_id: instruments(:voo_arcx).id,
          from: Date.new(2026, 8, 1), to: Date.new(2026, 8, 2), target_scope: target.scope,
          target_run_id: target.run_id, batch_scope: @batch.scope, batch_run_id: @batch.run_id
        )
      end
    end

    assert_equal [ true ], calls
    assert_predicate RefreshStatus::State.read(target.scope), :failed?
    assert_predicate RefreshStatus::State.read(@batch.scope), :failed?
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name) do |*arguments, **keywords, &block|
      replacement.call(*arguments, **keywords, &block)
    end
    yield
  ensure
    object.define_singleton_method(method_name) do |*arguments, **keywords, &block|
      original.call(*arguments, **keywords, &block)
    end
  end
end
