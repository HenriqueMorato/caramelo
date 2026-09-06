class RecoverDailyClosingPricesJob < ApplicationJob
  queue_as :market_prices

  include MarketData::Recoveries::JobSupport

  def perform(instrument_id:, from:, to:, target_scope:, target_run_id:, batch_scope:, batch_run_id:, lease_token: nil, lease_target: nil)
    run_target(target_scope:, target_run_id:, batch_scope:, batch_run_id:, lease_token:, lease_target:) do
      instrument = Instrument.find(instrument_id)
      MarketData::YahooFinance::RequestThrottle.new.wait!(instrument:)
      DailyClosingPrice::Importer.default.call(
        instrument:, from:, to:, enqueue_performance_rebuild: true
      )
    end
  end
end
