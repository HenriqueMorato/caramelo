module ExchangeRate
  module Providers
    class YahooFinance
      IDENTIFIER = MarketData::YahooFinance::FX_PROVIDER_IDENTIFIER

      def initialize(client: default_client)
        @client = client
      end

      def identifier = IDENTIFIER

      def fetch(base_currency:, quote_currency:)
        result = client.rate(base_currency:, quote_currency:)
        ExchangeRate::Rate.new(
          base_currency:, quote_currency:, rate: result.rate,
          observed_at: result.observed_at,
          fetched_at: Time.current,
          provider: identifier
        )
      rescue MarketData::YahooFinance::Error => error
        raise ExchangeRate::InvalidValue, error.message
      end

      private

      attr_reader :client

      def default_client
        MarketData::YahooFinance::FxClient.new(
          transport: MarketData::YahooFinance::CurlTransport.new(
            executable: ENV.fetch("YAHOO_FINANCE_HTTP_EXECUTABLE", MarketData::YahooFinance::DEFAULT_EXECUTABLE),
            timeout: MarketData::YahooFinance::FX_TIMEOUT
          )
        )
      end
    end
  end
end
