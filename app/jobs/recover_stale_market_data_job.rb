class RecoverStaleMarketDataJob < ApplicationJob
  queue_as :maintenance

  limits_concurrency key: ->(*) { "market-data:stale-recovery" }, duration: 2.minutes, on_conflict: :block

  def perform
    performance = Performance::StaleRefreshRecovery.call
    corporate_actions = CorporateActionImports::StaleScanRecovery.call
    broadcast_health if performance.changed? || corporate_actions.changed?

    [ performance.recovered_count, corporate_actions.recovered_count ].sum
  end

  private

  def broadcast_health
    MarketData::HealthReportBroadcaster.refresh
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { source: "stale_market_data_recovery" })
  end
end
