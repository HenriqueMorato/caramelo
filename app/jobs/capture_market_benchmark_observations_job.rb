class CaptureMarketBenchmarkObservationsJob < ApplicationJob
  queue_as :market_prices

  def perform(observed_on: TradingCalendar.previous_business_day, from: observed_on)
    benchmark_records = benchmarks
    RefreshStatus::Tracker.perform(scope: "market_benchmarks", total_count: benchmark_records.count) do |refresh|
      benchmark_records.find_each do |benchmark|
        next unless importer.supports?(benchmark:)
        next if captured?(benchmark, from:, to: observed_on)

        throttle.wait!
        importer.call(benchmark:, from:, to: observed_on, fence: publication_fence(benchmark:))
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { benchmark_id: benchmark.id, observed_on: })
        RefreshStatus::Tracker.record_failure(refresh, error)
      ensure
        RefreshStatus::Tracker.advance(refresh)
      end
    end
  end

  private

  def importer
    @importer ||= MarketBenchmark::Importer.default
  end

  def throttle
    @throttle ||= MarketData::YahooFinance::RequestThrottle.new
  end

  def benchmarks
    MarketBenchmark.all
  end

  def captured?(benchmark, from:, to:)
    from == to && MarketBenchmarkObservation.exists?(
      market_benchmark: benchmark, observed_on: to, provider: benchmark.provider
    )
  end

  def publication_fence(benchmark:)
    MarketData::PublicationFence.new(
      target: MarketData::Target.new(kind: :benchmark_observations, record_id: benchmark.id,
        provider: benchmark.provider)
    )
  end
end
