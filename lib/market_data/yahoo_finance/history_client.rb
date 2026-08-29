module MarketData
  module YahooFinance
    class HistoryClient
      ENDPOINT_PATH = "/v8/finance/chart"
      SUCCESS_RANGE = 200..299

      def initialize(transport:)
        @transport = transport
      end

      def daily_closes(identifier:, from:, to:)
        response = transport.get(chart_uri(identifier:, from:, to:))
        raise Error, "Yahoo Finance returned HTTP #{response.status}" unless SUCCESS_RANGE.cover?(response.status)

        payload = JSON.parse(response.body, decimal_class: BigDecimal)
        chart = payload.fetch("chart")
        raise InvalidResponse, chart.fetch("error").to_s if chart["error"]

        results = chart.fetch("result")
        raise InvalidResponse, "expected exactly one chart result" unless results.is_a?(Array) && results.one?

        parse_daily_closes(results.first, identifier:)
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
        raise InvalidResponse, error.message
      end

      private

      attr_reader :transport

      def chart_uri(identifier:, from:, to:)
        URI::HTTPS.build(
          host: CurlTransport::ALLOWED_HOST,
          path: "#{ENDPOINT_PATH}/#{identifier.value}",
          query: URI.encode_www_form(
            period1: from.beginning_of_day.to_i,
            period2: (to + 1).beginning_of_day.to_i,
            interval: "1d",
            events: "history"
          )
        )
      end

      def parse_daily_closes(result, identifier:)
        meta = result.fetch("meta")
        raise InvalidResponse, "response symbol does not match request" unless meta.fetch("symbol") == identifier.value
        unless identifier.matches_provider_exchange?(meta.fetch("exchangeName"))
          raise InvalidResponse, "response exchange does not match request"
        end
        unless identifier.supports_instrument_type?(meta.fetch("instrumentType"))
          raise InvalidResponse, "response instrument type is not supported"
        end
        currency = normalize_currency(meta.fetch("currency"))
        timestamps = result.fetch("timestamp")
        closes = result.fetch("indicators").fetch("quote").first.fetch("close")
        raise InvalidResponse, "history timestamps and closes differ in length" unless timestamps.length == closes.length

        timestamps.zip(closes).filter_map do |timestamp, close|
          next if close.nil?

          price = normalize_price(close)
          observed_at = Time.at(Integer(timestamp)).utc
          DailyClose.new(close_price: price, currency:, trading_date: observed_at.to_date, observed_at:)
        end
      end

      def normalize_price(value)
        raise InvalidResponse, "close price must not be a float" if value.is_a?(Float)

        price = BigDecimal(value.to_s)
        raise InvalidResponse, "close price must be finite and positive" unless price.finite? && price.positive?

        price
      rescue ArgumentError
        raise InvalidResponse, "close price is invalid"
      end

      def normalize_currency(value)
        currency = value.to_s.strip.upcase
        raise InvalidResponse, "currency is invalid" unless currency.match?(/\A[A-Z]{3}\z/)

        currency
      end

      DailyClose = Data.define(:close_price, :currency, :trading_date, :observed_at)
    end
  end
end
