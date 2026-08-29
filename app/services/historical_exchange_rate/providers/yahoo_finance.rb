class HistoricalExchangeRate
  module Providers
    class YahooFinance
      IDENTIFIER = MarketData::YahooFinance::FX_CONFIGURATION.identifier

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
        CurrencyCode.normalize(currency)
      end

      def default_client
        MarketData::YahooFinance::FxHistoryClient.new(
          transport: MarketData::YahooFinance::CurlTransport.from_configuration(
            MarketData::YahooFinance::FX_CONFIGURATION
          )
        )
      end
    end
  end
end
