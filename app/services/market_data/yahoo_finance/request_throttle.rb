module MarketData
  module YahooFinance
    class RequestThrottle < MarketData::RequestThrottle
      DEFAULT_INTERVAL = 1.second

      def initialize(cache: Rails.cache, interval: configured_interval, clock: -> { Time.current }, sleeper: Kernel.method(:sleep))
        super(provider: MARKET_PROVIDER_IDENTIFIER, interval:, cache:, clock:, sleeper:)
      end

      private

      def configured_interval
        environment_key = "YAHOO_FINANCE_MINIMUM_INTERVAL_SECONDS"
        seconds = Float(ENV.fetch(environment_key, DEFAULT_INTERVAL.to_f))
        raise ArgumentError, "interval must be positive" unless seconds.positive?

        seconds.seconds
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{environment_key} must be positive"
      end
    end
  end
end
