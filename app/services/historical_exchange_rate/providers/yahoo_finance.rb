class HistoricalExchangeRate
  module Providers
    class YahooFinance
      IDENTIFIER = MarketData::YahooFinance::FX_PROVIDER_IDENTIFIER

      def initialize(client: default_client)
        @client = client
      end

      def identifier = IDENTIFIER

      def fetch(base_currency:, quote_currency:, from:, to:)
        base_currency = normalize_currency(base_currency)
        quote_currency = normalize_currency(quote_currency)
        raise ArgumentError, "currencies must differ" if base_currency == quote_currency

        fetched_at = Time.current
        client.daily_rates(base_currency:, quote_currency:, from:, to:).map do |rate|
          HistoricalExchangeRate::Observation.new(
            base_currency:, quote_currency:, rate_date: rate.rate_date, rate: rate.rate,
            provider: identifier, observed_at: rate.observed_at, fetched_at:
          )
        end
      end

      private

      attr_reader :client

      def normalize_currency(currency)
        iso_code = currency.to_s.strip.upcase
        raise ArgumentError, "currency is invalid" unless Money::Currency.find(iso_code)

        iso_code
      end

      def default_client
        MarketData::YahooFinance::FxHistoryClient.new(
          transport: MarketData::YahooFinance::CurlTransport.new(
            executable: ENV.fetch("YAHOO_FINANCE_HTTP_EXECUTABLE", MarketData::YahooFinance::DEFAULT_EXECUTABLE),
            timeout: MarketData::YahooFinance::FX_TIMEOUT
          )
        )
      end
    end
  end
end
