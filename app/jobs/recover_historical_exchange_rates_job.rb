class RecoverHistoricalExchangeRatesJob < ApplicationJob
  queue_as :market_prices

  include MarketData::Recoveries::JobSupport

  def perform(base_currency:, quote_currency:, from:, to:, target_scope:, target_run_id:, batch_scope:, batch_run_id:, lease_token: nil, lease_target: nil)
    run_target(target_scope:, target_run_id:, batch_scope:, batch_run_id:, lease_token:, lease_target:) do
      MarketData::YahooFinance::RequestThrottle.new.wait!
      HistoricalExchangeRate::Importer.default.call(
        base_currency:, quote_currency:, from:, to:, enqueue_performance_rebuild: true
      )
    end
  end
end
