require "test_helper"

class CaptureMarketBenchmarkObservationsJobTest < ActiveJob::TestCase
  setup do
    MarketBenchmarkObservation.delete_all
    MarketBenchmark.delete_all
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

    assert_equal({ benchmark:, from: date, to: date }, imports.last)
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
end
