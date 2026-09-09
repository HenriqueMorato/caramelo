class MarketBenchmark
  module Providers
    class Bcb
      IDENTIFIER = "bcb"

      def initialize(client: MarketData::Bcb::Client.new)
        @client = client
      end

      def identifier = IDENTIFIER

      def supports?(benchmark:)
        benchmark.provider == identifier && benchmark.rate? && benchmark.provider_identifier.to_s.casecmp("CDI").zero?
      end

      def fetch(benchmark:, from:, to:)
        return [] unless supports?(benchmark:)

        client.daily_rates(identifier: benchmark.provider_identifier, from:, to:).map do |rate|
          MarketBenchmarkObservation::Observation.new(
            market_benchmark: benchmark, observed_on: rate.observed_on, value: rate.value,
            currency: benchmark.currency, provider: identifier, observed_at: rate.observed_at
          )
        end
      end

      private

      attr_reader :client
    end
  end
end
