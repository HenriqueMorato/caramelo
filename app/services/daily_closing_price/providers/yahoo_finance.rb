class DailyClosingPrice
  module Providers
    class YahooFinance
      IDENTIFIER = MarketData::YahooFinance::MARKET_PROVIDER_IDENTIFIER

      def initialize(client: default_client)
        @client = client
      end

      def identifier = IDENTIFIER

      def fetch(instrument:, from:, to:)
        return [] unless MarketData::YahooFinance::Identifier.supports_mic?(instrument.exchange)

        client.daily_closes(
          identifier: MarketData::YahooFinance::Identifier.build(ticker: instrument.ticker, mic: instrument.exchange),
          from:, to:
        ).map do |close|
          DailyClosingPrice::Observation.new(
            instrument:, trading_date: close.trading_date, close_price: close.close_price,
            currency: close.currency, provider: identifier, observed_at: close.observed_at
          )
        end
      end

      private

      attr_reader :client

      def default_client
        MarketData::YahooFinance::HistoryClient.new(
          transport: MarketData::YahooFinance::CurlTransport.from_environment(
            timeout: MarketData::YahooFinance::MARKET_TIMEOUT
          )
        )
      end
    end
  end
end
