module MarketData
  module YahooFinance
    class Configuration
      attr_reader :identifier, :timeout

      def initialize(identifier:, timeout:, interval_environment_variable:, default_interval: 1.second)
        @identifier = identifier
        @timeout = timeout
        @interval_environment_variable = interval_environment_variable
        @default_interval = default_interval
      end

      def executable
        ENV.fetch("YAHOO_FINANCE_HTTP_EXECUTABLE", MarketData::YahooFinance::DEFAULT_EXECUTABLE)
      end

      def interval
        seconds = Float(ENV.fetch(interval_environment_variable, default_interval.to_f))
        raise ArgumentError, "interval must be positive" unless seconds.positive?

        seconds.seconds
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{interval_environment_variable} must be positive"
      end

      private

      attr_reader :interval_environment_variable, :default_interval
    end
  end
end
