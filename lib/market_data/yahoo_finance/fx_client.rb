module MarketData
  module YahooFinance
    class FxClient
      ENDPOINT_PATH = "/v8/finance/chart"
      SUCCESS_RANGE = 200..299

      def initialize(transport:)
        @transport = transport
      end

      def rate(base_currency:, quote_currency:)
        response = transport.get(chart_uri(base_currency:, quote_currency:))
        raise Error, "Yahoo Finance returned HTTP #{response.status}" unless SUCCESS_RANGE.cover?(response.status)

        payload = JSON.parse(response.body, decimal_class: BigDecimal)
        results = payload.fetch("chart").fetch("result")
        raise InvalidResponse, "expected exactly one FX result" unless results.is_a?(Array) && results.one?

        meta = results.first.fetch("meta")
        rate = BigDecimal(meta.fetch("regularMarketPrice").to_s)
        raise InvalidResponse, "FX rate must be finite and positive" unless rate.finite? && rate.positive?
        currency = meta.fetch("currency").to_s.upcase
        raise InvalidResponse, "FX response currency does not match quote" unless currency == quote_currency

        Rate.new(rate:, observed_at: Time.at(Integer(meta.fetch("regularMarketTime"))).utc)
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
        raise InvalidResponse, error.message
      end

      Rate = Data.define(:rate, :observed_at)

      private

      attr_reader :transport

      def chart_uri(base_currency:, quote_currency:)
        symbol = "#{base_currency}#{quote_currency}=X"
        URI::HTTPS.build(
          host: CurlTransport::ALLOWED_HOST,
          path: "#{ENDPOINT_PATH}/#{URI::DEFAULT_PARSER.escape(symbol)}",
          query: URI.encode_www_form(range: "1d", interval: "1d")
        )
      end
    end
  end
end
