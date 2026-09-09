require "test_helper"

class MarketData::StartupRefreshTest < ActiveSupport::TestCase
  test "enqueues each startup market-data pass" do
    events = []
    enqueued_scopes = []
    with_stubbed_method(RefreshStatus::Tracker, :enqueue, ->(**attributes) { enqueued_scopes << attributes }) do
      with_stubbed_method(RefreshTradedMarketPricesJob, :enqueue_for, -> { events << :prices }) do
        with_stubbed_method(CaptureDailyClosingPricesJob, :perform_later, -> { events << :closes }) do
          with_stubbed_method(CaptureHistoricalExchangeRatesJob, :perform_later, -> { events << :fx }) do
            with_stubbed_method(CaptureMarketBenchmarkObservationsJob, :perform_later, lambda { |**arguments|
              events << [ :benchmarks, arguments ]
            }) do
              with_stubbed_method(InstrumentPerformance::StartupPreparation, :call, -> { events << :instrument_performance }) do
                MarketData::StartupRefresh.call
              end
            end
          end
        end
      end
    end

    assert_equal %i[prices closes fx], events.first(3)
    benchmark_event = events.find { |event| event.is_a?(Array) && event.first == :benchmarks }
    assert_equal :benchmarks, benchmark_event.first
    assert_equal Trade.where(user: User.owner).minimum(:traded_on), benchmark_event.last.fetch(:from)
    assert_includes events, :instrument_performance
    assert_equal 1, enqueued_scopes.count { |attributes| attributes[:scope] == "current_market_prices" }
    assert_equal Trade.where(user: User.owner).distinct.count(:instrument_id),
      enqueued_scopes.find { |attributes| attributes[:scope] == "current_market_prices" }[:total_count]
  end

  test "uses the previous business day as the benchmark start when the owner has no trades" do
    Trade.delete_all

    assert_equal TradingCalendar.previous_business_day,
      MarketData::StartupRefresh.send(:benchmark_history_start)
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    object.singleton_class.define_method(method_name, original)
  end
end
