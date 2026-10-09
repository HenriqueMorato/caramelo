require "test_helper"

class CaptureMarketBenchmarkObservationsJobTest < ActiveJob::TestCase
  setup do
    MarketBenchmarkObservation.delete_all
    MarketBenchmark.delete_all
  end

  test "builds the default importer and throttle" do
    job = CaptureMarketBenchmarkObservationsJob.new

    assert_instance_of MarketBenchmark::Importer, job.send(:importer)
    assert_instance_of MarketData::YahooFinance::RequestThrottle, job.send(:throttle)
  end

  test "reports an import failure" do
    benchmark = create_benchmark
    reports = []
    importer = Object.new
    importer.define_singleton_method(:identifier) { "yahoo_finance" }
    importer.define_singleton_method(:supports?) { |benchmark:| true }
    importer.define_singleton_method(:call) { |**| raise "provider unavailable" }
    job = CaptureMarketBenchmarkObservationsJob.new
    job.define_singleton_method(:importer) { importer }
    throttle = Object.new
    throttle.define_singleton_method(:wait!) { }
    job.define_singleton_method(:throttle) { throttle }

    with_stubbed_method(Rails.error, :report, ->(error, **context) { reports << [ error, context ] }) do
      job.perform(observed_on: Date.new(2026, 8, 28))
    end

    assert_equal 1, reports.size
    assert_equal benchmark.id, reports.first.last[:context][:benchmark_id]
  end

  test "uses the prior Friday when the scheduled run is on Monday" do
    benchmark = create_benchmark
    imports = []
    importer = Object.new
    importer.define_singleton_method(:identifier) { "yahoo_finance" }
    importer.define_singleton_method(:supports?) { |benchmark:| true }
    importer.define_singleton_method(:call) { |**arguments| imports << arguments }
    job = CaptureMarketBenchmarkObservationsJob.new
    job.define_singleton_method(:importer) { importer }
    throttle = Object.new
    throttle.define_singleton_method(:wait!) { }
    job.define_singleton_method(:throttle) { throttle }

    with_stubbed_class_method(Date, :current, -> { Date.new(2026, 8, 31) }) { job.perform }

    assert_equal Date.new(2026, 8, 28), imports.first[:from]
    assert_equal benchmark, imports.first[:benchmark]
  end

  test "imports supported benchmarks for the requested trading day" do
    benchmark = create_benchmark
    imports = []
    throttle = Object.new
    throttle.define_singleton_method(:wait!) { imports << :wait }
    importer = Object.new
    importer.define_singleton_method(:identifier) { "yahoo_finance" }
    importer.define_singleton_method(:supports?) { |benchmark:| benchmark.provider == "yahoo_finance" }
    importer.define_singleton_method(:call) { |**arguments| imports << arguments }
    job = CaptureMarketBenchmarkObservationsJob.new
    job.define_singleton_method(:importer) { importer }
    job.define_singleton_method(:throttle) { throttle }

    date = Date.new(2026, 8, 28)
    job.perform(observed_on: date)

    assert_equal({ benchmark:, from: date, to: date }, imports.last.slice(:benchmark, :from, :to))
  end

  test "uses a recent overlap for daily CDI captures" do
    benchmark = MarketBenchmark.create!(identifier: "CDI", name: "CDI", kind: :rate, currency: "BRL",
      provider: "bcb", provider_identifier: "CDI")
    imports = []
    importer = Object.new
    importer.define_singleton_method(:identifier) { "bcb" }
    importer.define_singleton_method(:supports?) { |benchmark:| benchmark.provider == "bcb" }
    importer.define_singleton_method(:call) { |**arguments| imports << arguments }
    job = CaptureMarketBenchmarkObservationsJob.new
    job.define_singleton_method(:importer) { importer }
    job.define_singleton_method(:throttle) { Object.new.tap { |object| object.define_singleton_method(:wait!) { } } }

    date = Date.new(2026, 9, 8)
    job.perform(observed_on: date)

    assert_equal date - 7.days, imports.sole[:from]
    assert_equal date, imports.sole[:to]
  end

  test "does not skip CDI when the target date was already captured" do
    benchmark = MarketBenchmark.create!(identifier: "CDI", name: "CDI", kind: :rate, currency: "BRL",
      provider: "bcb", provider_identifier: "CDI")
    MarketBenchmarkObservation.create!(market_benchmark: benchmark, observed_on: Date.new(2026, 9, 8), value: 1,
      currency: "BRL", provider: "bcb", observed_at: Time.current)
    imports = []
    importer = Object.new
    importer.define_singleton_method(:identifier) { "bcb" }
    importer.define_singleton_method(:supports?) { |benchmark:| benchmark.provider == "bcb" }
    importer.define_singleton_method(:call) { |**arguments| imports << arguments }
    job = CaptureMarketBenchmarkObservationsJob.new
    job.define_singleton_method(:importer) { importer }
    job.define_singleton_method(:throttle) { Object.new.tap { |object| object.define_singleton_method(:wait!) { } } }

    job.perform(observed_on: Date.new(2026, 9, 8))

    assert_equal 1, imports.size
  end

  test "audits benchmark history across the requested startup range" do
    benchmark = create_benchmark
    imports = []
    importer = Object.new
    importer.define_singleton_method(:identifier) { "yahoo_finance" }
    importer.define_singleton_method(:supports?) { |benchmark:| true }
    importer.define_singleton_method(:call) { |**arguments| imports << arguments }
    job = CaptureMarketBenchmarkObservationsJob.new
    job.define_singleton_method(:importer) { importer }
    job.define_singleton_method(:throttle) { Object.new.tap { |object| object.define_singleton_method(:wait!) { } } }

    from = Date.new(2026, 1, 5)
    to = Date.new(2026, 8, 28)
    job.perform(observed_on: to, from:)

    assert_equal({ benchmark:, from:, to: }, imports.sole.slice(:benchmark, :from, :to))
  end

  test "does not request a benchmark before its provider source begins" do
    benchmark = MarketBenchmark.create!(identifier: "ACWI_SOURCE", name: "Global index", kind: :total_return,
      currency: "USD", provider: "yahoo_finance", provider_identifier: "IMID.L", return_convention: :net)
    imports = []
    importer = Object.new
    importer.define_singleton_method(:identifier) { "yahoo_finance" }
    importer.define_singleton_method(:supports?) { |benchmark:| benchmark.provider == "yahoo_finance" }
    importer.define_singleton_method(:available_from_for) { |benchmark:| Date.new(2011, 7, 26) }
    importer.define_singleton_method(:call) { |**arguments| imports << arguments }
    job = CaptureMarketBenchmarkObservationsJob.new
    job.define_singleton_method(:importer) { importer }
    throttle = Object.new
    throttle.define_singleton_method(:wait!) { }
    job.define_singleton_method(:throttle) { throttle }
    job.perform(observed_on: Date.new(2026, 8, 28), from: Date.new(2000, 1, 1))

    assert_equal Date.new(2011, 7, 26), imports.sole[:from]
  end

  test "skips a benchmark capture when the provider source begins after the target date" do
    create_benchmark
    imports = []
    importer = Object.new
    importer.define_singleton_method(:identifier) { "yahoo_finance" }
    importer.define_singleton_method(:supports?) { |benchmark:| true }
    importer.define_singleton_method(:available_from_for) { |benchmark:| Date.new(2027, 1, 1) }
    importer.define_singleton_method(:call) { |**arguments| imports << arguments }
    job = CaptureMarketBenchmarkObservationsJob.new
    job.define_singleton_method(:importer) { importer }
    job.define_singleton_method(:throttle) { Object.new.tap { |object| object.define_singleton_method(:wait!) { } } }

    job.perform(observed_on: Date.new(2026, 8, 28))

    assert_empty imports
  end

  test "skips unsupported and already captured benchmarks" do
    supported = create_benchmark
    unsupported = MarketBenchmark.create!(
      identifier: "CDI", name: "CDI", kind: "rate", currency: "BRL",
      provider: "bcb", provider_identifier: "CDI"
    )
    MarketBenchmarkObservation.create!(
      market_benchmark: supported, observed_on: Date.new(2026, 8, 28), value: 1,
      currency: "USD", provider: "yahoo_finance", observed_at: Time.current
    )
    calls = []
    importer = Object.new
    importer.define_singleton_method(:identifier) { "yahoo_finance" }
    importer.define_singleton_method(:supports?) { |benchmark:| calls << benchmark; benchmark.provider == "yahoo_finance" }
    importer.define_singleton_method(:call) { |**| flunk "existing observation should not be imported" }
    job = CaptureMarketBenchmarkObservationsJob.new
    job.define_singleton_method(:importer) { importer }

    job.perform(observed_on: Date.new(2026, 8, 28))

    assert_equal [ supported, unsupported ], calls
  end

  private

  def create_benchmark
    MarketBenchmark.create!(
      identifier: "SP500", name: "S&P 500", kind: "price", currency: "USD",
      provider: "yahoo_finance", provider_identifier: "^GSPC"
    )
  end

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
