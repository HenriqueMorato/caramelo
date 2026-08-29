module MarketData
  module YahooFinance
    class RequestThrottle < MarketData::RequestThrottle
      def initialize(cache: Rails.cache, interval: configured_interval, clock: -> { Time.current }, sleeper: Kernel.method(:sleep))
        super(provider: MARKET_CONFIGURATION.identifier, interval:, cache:, clock:, sleeper:)
      end

      private

      def configured_interval
        MARKET_CONFIGURATION.interval
      end
    end
  end
end
