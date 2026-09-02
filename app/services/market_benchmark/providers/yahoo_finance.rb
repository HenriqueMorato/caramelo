class MarketBenchmark
  module Providers
    class YahooFinance
      IDENTIFIER = MarketData::YahooFinance::MARKET_CONFIGURATION.identifier
      YahooBenchmarkIdentifier = Data.define(:value) do
        def matches_provider_exchange?(_exchange) = true
        def supports_instrument_type?(type) = type == "INDEX"
      end

      def initialize(client: default_client)
        @client = client
      end

      def identifier = IDENTIFIER

      def supports?(benchmark:)
        benchmark.provider == identifier && benchmark.kind == "price"
      end

      def fetch(benchmark:, from:, to:)
        return [] unless supports?(benchmark:)

        client.daily_closes(
          identifier: benchmark_identifier(benchmark), from:, to:
        ).map do |close|
          MarketBenchmarkObservation::Observation.new(
            market_benchmark: benchmark, observed_on: close.trading_date, value: close.close_price,
            currency: close.currency, provider: identifier, observed_at: close.observed_at
          )
        end
      end

      private

      attr_reader :client

      def benchmark_identifier(benchmark)
        value = benchmark.provider_identifier.to_s.strip
        raise MarketData::YahooFinance::InvalidIdentifier, "benchmark identifier is invalid" if value.empty?

        YahooBenchmarkIdentifier.new(value).freeze
      end

      def default_client
        MarketData::YahooFinance::HistoryClient.new(
          transport: MarketData::YahooFinance::CurlTransport.from_configuration(
            MarketData::YahooFinance::MARKET_CONFIGURATION
          )
        )
      end
    end
  end
end
