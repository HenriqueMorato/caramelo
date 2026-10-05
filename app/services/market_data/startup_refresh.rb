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
      CaptureMarketBenchmarkObservationsJob.perform_later(from: benchmark_history_start)
      InstrumentPerformance::StartupPreparation.call
      CorporateActionImports::Automation.call
    end

    def self.traded_instrument_count
      Trade.where(user: User.owner).distinct.count(:instrument_id)
    end

    def self.benchmark_history_start
      oldest_activity_date = [
        Trade.where(user: User.owner).minimum(:traded_on),
        CorporateAction.where(user: User.owner).effective_on_or_before(Date.current).minimum_performance_on
      ].compact.min
      [ oldest_activity_date, TradingCalendar.previous_business_day ].compact.min
    end

    private_class_method :traded_instrument_count, :benchmark_history_start
  end
end
