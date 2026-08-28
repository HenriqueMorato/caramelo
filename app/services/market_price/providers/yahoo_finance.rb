module MarketPrice
  module Providers
    class YahooFinance
      IDENTIFIER = "yahoo_finance"
      DEFAULT_EXECUTABLE = "curl_chrome146"
      DEFAULT_TIMEOUT = 15

      def initialize(client: nil, executable: ENV.fetch("YAHOO_FINANCE_HTTP_EXECUTABLE", DEFAULT_EXECUTABLE),
        timeout: DEFAULT_TIMEOUT)
        @client = client
        @executable = executable
        @timeout = Integer(timeout)
      end

      def identifier
        IDENTIFIER
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
        raise ProviderFailure.new(provider_identifier: identifier, message: error.message), cause: error
      end

      private

      attr_reader :executable, :timeout

      def client
        @client ||= MarketData::YahooFinance::Client.new(
          transport: MarketData::YahooFinance::CurlTransport.new(executable:, timeout:)
        )
      end
    end
  end
end
