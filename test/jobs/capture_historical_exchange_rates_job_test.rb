require "test_helper"

class CaptureHistoricalExchangeRatesJobTest < ActiveJob::TestCase
  test "builds the default importer and throttle" do
    job = CaptureHistoricalExchangeRatesJob.new

    assert_instance_of HistoricalExchangeRate::Importer, job.send(:importer)
    assert_instance_of MarketPrice::RequestThrottle, job.send(:throttle)
  end

  test "imports one rate for each traded currency outside reporting currency" do
    date = Date.new(2026, 8, 28)
    imports = []
    waits = 0
    throttle = Object.new
    throttle.define_singleton_method(:wait!) { waits += 1 }
    importer = Object.new
    importer.define_singleton_method(:call) { |**arguments| imports << arguments }
    job = CaptureHistoricalExchangeRatesJob.new
    job.define_singleton_method(:importer) { importer }
    job.define_singleton_method(:throttle) { throttle }

    job.perform(rate_date: date)

    assert_equal [ "USD" ], imports.map { |call| call[:base_currency] }
    assert_equal [ "BRL" ], imports.map { |call| call[:quote_currency] }.uniq
    assert_equal [ { from: date, to: date } ], imports.map { |call| call.slice(:from, :to) }
    assert_equal 1, waits
  end

  test "reports a failure and continues with other currencies" do
    date = Date.new(2026, 8, 28)
    reports = []
    importer = Object.new
    importer.define_singleton_method(:call) { |**| raise "provider unavailable" }
    throttle = Object.new
    throttle.define_singleton_method(:wait!) { }
    job = CaptureHistoricalExchangeRatesJob.new
    job.define_singleton_method(:importer) { importer }
    job.define_singleton_method(:throttle) { throttle }

    with_stubbed_method(Rails.error, :report, ->(error, **context) { reports << [ error, context ] }) do
      job.perform(rate_date: date)
    end

    assert_equal 1, reports.size
    assert_equal "USD", reports.first.last[:context][:currency]
    assert_equal date, reports.first.last[:context][:rate_date]
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
