require "test_helper"

class CaptureDailyClosingPricesJobTest < ActiveJob::TestCase
  test "builds the default importer and throttle" do
    job = CaptureDailyClosingPricesJob.new

    assert_instance_of DailyClosingPrice::Importer, job.send(:importer)
    assert_instance_of MarketData::YahooFinance::RequestThrottle, job.send(:request_throttle)
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
    job.define_singleton_method(:request_throttle) { throttle }

    job.perform(trading_date: date)

    assert_equal Trade.where(user: User.owner).distinct.pluck(:instrument_id).sort, imports.map { |call| call[:instrument].id }.sort
    assert imports.all? { |call| call.slice(:from, :to) == { from: date, to: date } }
  end

  test "skips an instrument with an existing observation" do
    instrument = Trade.where(user: User.owner).first.instrument
    DailyClosingPrice.create!(instrument:, trading_date: Date.new(2026, 8, 28), close_price: 30,
      currency: instrument.currency, provider: DailyClosingPrice::Providers::YahooFinance::IDENTIFIER,
      observed_at: Time.current)
    imports = []
    importer = Object.new
    importer.define_singleton_method(:call) { |**arguments| imports << arguments }
    job = CaptureDailyClosingPricesJob.new
    job.define_singleton_method(:importer) { importer }
    job.define_singleton_method(:request_throttle) { Object.new }

    job.perform(trading_date: Date.new(2026, 8, 28))

    assert_empty imports.select { |call| call[:instrument] == instrument }
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
    job.define_singleton_method(:request_throttle) { throttle }

    with_stubbed_method(Rails.error, :report, ->(error, **context) { reports << [ error, context ] }) do
      job.perform(trading_date: date)
    end

    assert_equal 1, reports.size
    assert_equal date, reports.first.last[:context][:trading_date]
    assert_equal "failed", RefreshStatus::State.read("daily_closing_prices").status
  end

  test "uses the prior Friday when the scheduled run is on Monday" do
    imports = []
    importer = Object.new
    importer.define_singleton_method(:call) { |**arguments| imports << arguments }
    throttle = Object.new
    throttle.define_singleton_method(:wait!) { |instrument:| }
    job = CaptureDailyClosingPricesJob.new
    job.define_singleton_method(:importer) { importer }
    job.define_singleton_method(:request_throttle) { throttle }

    with_stubbed_class_method(Date, :current, -> { Date.new(2026, 8, 31) }) { job.perform }

    assert imports.all? { |call| call.slice(:from, :to) == { from: Date.new(2026, 8, 28), to: Date.new(2026, 8, 28) } }
  end

  test "records one progress step per instrument" do
    importer = Object.new
    importer.define_singleton_method(:call) { |**| }
    throttle = Object.new
    throttle.define_singleton_method(:wait!) { |instrument:| }
    job = CaptureDailyClosingPricesJob.new
    job.define_singleton_method(:importer) { importer }
    job.define_singleton_method(:request_throttle) { throttle }

    with_stubbed_method(RefreshStatus::Broadcaster, :refresh, ->(**) { }) do
      job.perform(trading_date: Date.new(2026, 8, 28))
    end

    state = RefreshStatus::State.read("daily_closing_prices")
    assert_equal Trade.where(user: User.owner).distinct.count(:instrument_id), state.processed_count
  end

  private

  def with_stubbed_method(object, method_name, replacement)
    original = object.method(method_name)
    object.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    object.singleton_class.define_method(method_name, original)
  end

  def with_stubbed_class_method(klass, method_name, replacement)
    original = klass.method(method_name)
    klass.singleton_class.define_method(method_name, replacement)
    yield
  ensure
    klass.singleton_class.define_method(method_name, original)
  end
end
