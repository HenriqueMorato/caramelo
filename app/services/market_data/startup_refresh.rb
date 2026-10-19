module MarketData
  class StartupRefresh
    def self.call
      AssetType.ensure_defaults!
      MarketBenchmark.ensure_defaults!
      RefreshStatus::Tracker.enqueue(scope: RefreshStatus::MARKET_PRICE_SCOPE, total_count: traded_instrument_count)
      RefreshTradedMarketPricesJob.enqueue_for
      RefreshStatus::Tracker.enqueue(scope: "daily_closing_prices")
      CaptureDailyClosingPricesJob.perform_later
      RefreshStatus::Tracker.enqueue(scope: "historical_exchange_rates")
      CaptureHistoricalExchangeRatesJob.perform_later
      account_users.each { |user| PrepareReportingCurrencyJob.enqueue_for(user:) }
      RefreshStatus::Tracker.enqueue(scope: "market_benchmarks")
      CaptureMarketBenchmarkObservationsJob.perform_later(from: benchmark_history_start)
      if Caramelo::AccountMode.single?
        InstrumentPerformance::StartupPreparation.call
        CorporateActionImports::Automation.call
      else
        account_users.each do |user|
          InstrumentPerformance::StartupPreparation.call(user:)
          CorporateActionImports::Automation.call(user:)
        end
      end
    end

    def self.traded_instrument_count
      Trade.where(user: account_users).distinct.count(:instrument_id)
    end

    def self.benchmark_history_start
      oldest_activity_date = [
        Trade.where(user: account_users).minimum(:traded_on),
        CorporateAction.where(user: account_users).effective_on_or_before(Date.current).minimum_performance_on
      ].compact.min
      [ oldest_activity_date, TradingCalendar.previous_business_day ].compact.min
    end

    def self.account_users
      return [ User.default_owner ] if Caramelo::AccountMode.single?

      User.all.to_a
    end

    private_class_method :traded_instrument_count, :benchmark_history_start, :account_users
  end
end
