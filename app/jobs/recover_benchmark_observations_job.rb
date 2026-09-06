class RecoverBenchmarkObservationsJob < ApplicationJob
  queue_as :market_prices

  include MarketData::Recoveries::JobSupport

  def perform(benchmark_id:, from:, to:, target_scope:, target_run_id:, batch_scope:, batch_run_id:, lease_token: nil, lease_target: nil)
    run_target(target_scope:, target_run_id:, batch_scope:, batch_run_id:, lease_token:, lease_target:) do
      benchmark = MarketBenchmark.find(benchmark_id)
      importer = MarketBenchmark::Importer.default
      raise ArgumentError, "benchmark provider is unsupported" unless importer.supports?(benchmark:)

      MarketData::YahooFinance::RequestThrottle.new.wait!
      importer.call(benchmark:, from:, to:)
    end
  end
end
