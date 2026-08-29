require "test_helper"

class CaptureDailyClosingPricesJobTest < ActiveJob::TestCase
  test "builds the default importer and throttle" do
    job = CaptureDailyClosingPricesJob.new

    assert_instance_of DailyClosingPrice::Importer, job.send(:importer)
    assert_instance_of MarketPrice::RequestThrottle, job.send(:market_price_throttle)
  end

  test "imports one daily observation for each traded instrument" do
    date = Date.new(2026, 8, 28)
    imports = []
    throttle = Object.new
    throttle.define_singleton_method(:wait!) { |instrument:| }
    importer = Object.new
    importer.define_singleton_method(:call) { |**arguments| imports << arguments }
    job = CaptureDailyClosingPricesJob.new
    job.define_singleton_method(:importer) { importer }
    job.define_singleton_method(:market_price_throttle) { throttle }

    job.perform(trading_date: date)

    assert_equal Trade.where(user: User.owner).distinct.pluck(:instrument_id).sort, imports.map { |call| call[:instrument].id }.sort
    assert imports.all? { |call| call.slice(:from, :to) == { from: date, to: date } }
  end

  test "reports an import failure and continues with other instruments" do
    date = Date.new(2026, 8, 28)
    reports = []
    importer = Object.new
    importer.define_singleton_method(:call) do |instrument:, **|
      raise "provider unavailable" if instrument.id == Trade.where(user: User.owner).first.instrument_id
    end
    throttle = Object.new
    throttle.define_singleton_method(:wait!) { |instrument:| }
    job = CaptureDailyClosingPricesJob.new
    job.define_singleton_method(:importer) { importer }
    job.define_singleton_method(:market_price_throttle) { throttle }

    with_stubbed_method(Rails.error, :report, ->(error, **context) { reports << [ error, context ] }) do
      job.perform(trading_date: date)
    end

    assert_equal 1, reports.size
    assert_equal date, reports.first.last[:context][:trading_date]
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
