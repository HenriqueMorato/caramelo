module MarketData
  class StartupRefresh
    def self.call
      RefreshTradedMarketPricesJob.enqueue_for
      CaptureDailyClosingPricesJob.perform_later
      CaptureHistoricalExchangeRatesJob.perform_later
      CaptureMarketBenchmarkObservationsJob.perform_later
    end
  end
end
