module MarketData
  class StartupRefresh
    def self.call
      RefreshStatus::Tracker.enqueue(scope: RefreshStatus::MARKET_PRICE_SCOPE, total_count: traded_instrument_count)
      RefreshTradedMarketPricesJob.enqueue_for
      RefreshStatus::Tracker.enqueue(scope: "daily_closing_prices")
      CaptureDailyClosingPricesJob.perform_later
      RefreshStatus::Tracker.enqueue(scope: "historical_exchange_rates")
      CaptureHistoricalExchangeRatesJob.perform_later
      RefreshStatus::Tracker.enqueue(scope: "market_benchmarks")
      CaptureMarketBenchmarkObservationsJob.perform_later
    end

    def self.traded_instrument_count
      Trade.where(user: User.owner).distinct.count(:instrument_id)
    end

    private_class_method :traded_instrument_count
  end
end
