class CaptureMarketBenchmarkObservationsJob < ApplicationJob
  queue_as :market_prices

  def perform(observed_on: MarketData::TradingCalendar.previous_business_day)
    benchmarks.find_each do |benchmark|
      next unless importer.supports?(benchmark:)
      next if MarketBenchmarkObservation.exists?(market_benchmark: benchmark, observed_on:, provider: importer.identifier)

      throttle.wait!
      importer.call(benchmark:, from: observed_on, to: observed_on)
    rescue StandardError => error
      Rails.error.report(error, handled: true, context: { benchmark_id: benchmark.id, observed_on: })
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
end
