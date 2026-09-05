class RecoverCurrentExchangeRateJob < ApplicationJob
  queue_as :market_prices

  include MarketData::Recoveries::JobSupport

  def perform(base_currency:, quote_currency:, target_scope:, target_run_id:, batch_scope:, batch_run_id:)
    run_target(target_scope:, target_run_id:, batch_scope:, batch_run_id:) do
      MarketData::YahooFinance::RequestThrottle.new.wait!
      ExchangeRate::Service.default.refresh(base_currency:, quote_currency:, force: true)
    end
  end
end
