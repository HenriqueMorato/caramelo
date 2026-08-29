class DailyClosingPrice
  module Providers
    class YahooFinance
      IDENTIFIER = "yahoo_finance"

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
          transport: MarketData::YahooFinance::CurlTransport.new(
            executable: ENV.fetch("YAHOO_FINANCE_HTTP_EXECUTABLE", "curl_chrome146"), timeout: 15
          )
        )
      end
    end
  end
end
