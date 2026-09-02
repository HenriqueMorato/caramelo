require "test_helper"

class MarketData::StartupRefreshTest < ActiveSupport::TestCase
  test "enqueues each startup market-data pass" do
    events = []
    with_stubbed_method(RefreshTradedMarketPricesJob, :enqueue_for, -> { events << :prices }) do
      with_stubbed_method(CaptureDailyClosingPricesJob, :perform_later, -> { events << :closes }) do
        with_stubbed_method(CaptureHistoricalExchangeRatesJob, :perform_later, -> { events << :fx }) do
          with_stubbed_method(CaptureMarketBenchmarkObservationsJob, :perform_later, -> { events << :benchmarks }) do
            MarketData::StartupRefresh.call
          end
        end
      end
    end

    assert_equal %i[prices closes fx benchmarks], events
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
