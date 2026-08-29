module MarketPrice
  module Providers
    class YahooFinance
      def initialize(client: nil, configuration: MarketData::YahooFinance::MARKET_CONFIGURATION)
        @client = client
        @configuration = configuration
      end

      def identifier
        configuration.identifier
      end

      def supports?(instrument:)
        MarketData::YahooFinance::Identifier.supports_mic?(instrument.exchange)
      end

      def fetch(instrument:)
        quote = client.quote(
          MarketData::YahooFinance::Identifier.build(
            ticker: instrument.ticker,
            mic: instrument.exchange
          )
        )
        unless quote.currency == instrument.currency
          raise CurrencyMismatch, "#{quote.currency} does not match #{instrument.currency}"
        end

        CurrentMarketPrice.new(
          unit_price: quote.unit_price,
          currency: quote.currency,
          provider: identifier,
          quoted_at: quote.quoted_at,
          fetched_at: Time.current
        )
      rescue MarketData::YahooFinance::Error => error
        raise ProviderFailure.new(provider_identifier: identifier, message: error.message, cause: error), cause: error
      end

      private

      attr_reader :configuration

      def client
        @client ||= MarketData::YahooFinance::QuoteClient.new(
          transport: MarketData::YahooFinance::CurlTransport.from_configuration(configuration)
        )
      end
    end
  end
end
