module MarketData
  module YahooFinance
    class Identifier
      B3_MIC = "BVMF"
      US_MICS = %w[XNAS XNYS ARCX].freeze
      EXCHANGES = {
        B3_MIC => { suffix: ".SA", provider_exchanges: %w[SAO] },
        "XNAS" => { suffix: "", provider_exchanges: %w[NMS NGM NCM] },
        "XNYS" => { suffix: "", provider_exchanges: %w[NYQ] },
        "ARCX" => { suffix: "", provider_exchanges: %w[PCX] }
      }.freeze
      B3_TICKER_PATTERN = /\A[A-Z0-9]{4,12}\z/
      US_TICKER_PATTERN = /\A[A-Z0-9]+(?:[.-][A-Z0-9]+)?\z/
      MAX_TICKER_LENGTH = 12
      SUPPORTED_INSTRUMENT_TYPES = %w[EQUITY ETF].freeze

      attr_reader :mic, :value

      def self.build(ticker:, mic:)
        new(ticker:, mic:)
      end

      def self.supports_mic?(mic)
        EXCHANGES.key?(mic.to_s.strip.upcase)
      end

      # ticker is the exchange-listed symbol; mic is its ISO Market Identifier
      # Code. Together they identify a listing, such as AAPL on XNAS.
      def initialize(ticker:, mic:)
        @mic = mic.to_s.strip.upcase
        exchange = EXCHANGES[@mic]
        raise UnsupportedExchange, "exchange #{mic.inspect} is not supported" unless exchange

        normalized_ticker = ticker.to_s.strip.upcase
        unless valid_ticker?(normalized_ticker)
          raise InvalidIdentifier, "ticker #{ticker.inspect} is invalid"
        end

        provider_ticker = US_MICS.include?(@mic) ? normalized_ticker.tr(".", "-") : normalized_ticker
        @value = "#{provider_ticker}#{exchange.fetch(:suffix)}"
        freeze
      end

      def matches_provider_exchange?(provider_exchange)
        EXCHANGES.fetch(mic).fetch(:provider_exchanges).include?(provider_exchange)
      end

      def supports_instrument_type?(instrument_type)
        SUPPORTED_INSTRUMENT_TYPES.include?(instrument_type)
      end

      private

      def valid_ticker?(ticker)
        return false if ticker.length > MAX_TICKER_LENGTH

        pattern = mic == B3_MIC ? B3_TICKER_PATTERN : US_TICKER_PATTERN
        ticker.match?(pattern)
      end
    end
  end
end
