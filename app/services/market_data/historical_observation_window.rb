module MarketData
  class HistoricalObservationWindow
    # Covers ordinary weekends and short exchange holidays without accepting
    # indefinitely stale market data as a current valuation.
    MAXIMUM_LOOKBACK_DAYS = 7

    def self.for(date)
      (date - MAXIMUM_LOOKBACK_DAYS)..date
    end
  end
end
