module MarketData
  module YahooFinance
    class Identifier
      B3_MIC = "BVMF"
      B3_SUFFIX = ".SA"
      TICKER_PATTERN = /\A[A-Z0-9]{4,12}\z/

      attr_reader :value

      def self.build(ticker:, mic:)
        new(ticker:, mic:)
      end

      def initialize(ticker:, mic:)
        normalized_mic = mic.to_s.strip.upcase
        raise UnsupportedExchange, "exchange #{mic.inspect} is not supported" unless normalized_mic == B3_MIC

        normalized_ticker = ticker.to_s.strip.upcase
        unless normalized_ticker.match?(TICKER_PATTERN)
          raise InvalidIdentifier, "ticker #{ticker.inspect} is invalid"
        end

        @value = "#{normalized_ticker}#{B3_SUFFIX}"
        freeze
      end
    end
  end
end
