module ExchangeRate
  module Providers
    class YahooFinance
      IDENTIFIER = "yahoo_finance_fx"

      def initialize(client: default_client)
        @client = client
      end

      def identifier = IDENTIFIER

      def fetch(base_currency:, quote_currency:)
        result = client.rate(base_currency:, quote_currency:)
        ExchangeRate::Rate.new(
          base_currency:, quote_currency:, rate: result.rate,
          observed_on: result.observed_at.to_date,
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
            executable: ENV.fetch("YAHOO_FINANCE_HTTP_EXECUTABLE", "curl_chrome146"),
            timeout: 10
          )
        )
      end
    end
  end
end
