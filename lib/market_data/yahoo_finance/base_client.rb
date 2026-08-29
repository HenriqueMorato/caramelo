module MarketData
  module YahooFinance
    class BaseClient
      ENDPOINT_PATH = "/v8/finance/chart"
      SUCCESS_RANGE = 200..299

      def initialize(transport:)
        @transport = transport
      end

      private

      attr_reader :transport

      def chart_uri(identifier)
        chart_uri_for(value: identifier.value)
      end

      def chart_uri_for(value:)
        URI::HTTPS.build(
          host: CurlTransport::ALLOWED_HOST,
          path: "#{ENDPOINT_PATH}/#{value}",
          query: URI.encode_www_form(range: "1d", interval: "1d")
        )
      end

      def history_uri(identifier:, from:, to:)
        history_uri_for(value: identifier.value, from:, to:)
      end

      def history_uri_for(value:, from:, to:)
        URI::HTTPS.build(
          host: CurlTransport::ALLOWED_HOST,
          path: "#{ENDPOINT_PATH}/#{value}",
          query: URI.encode_www_form(
            period1: from.in_time_zone.beginning_of_day.to_i,
            period2: (to + 1).in_time_zone.beginning_of_day.to_i,
            interval: "1d",
            events: "history"
          )
        )
      end

      def classify_status!(response)
        return if SUCCESS_RANGE.cover?(response.status)

        error_class = case response.status
        when 401, 403 then Unauthorized
        when 404 then SymbolNotFound
        when 429 then RateLimited
        when 500..599 then ProviderUnavailable
        else HTTPError
        end

        raise error_class.new(status: response.status, headers: response.headers)
      end

      def validate_identifier!(meta, identifier)
        raise InvalidResponse, "response symbol does not match request" unless meta.fetch("symbol") == identifier.value
        unless identifier.matches_provider_exchange?(meta.fetch("exchangeName"))
          raise InvalidResponse, "response exchange does not match request"
        end
        unless identifier.supports_instrument_type?(meta.fetch("instrumentType"))
          raise InvalidResponse, "response instrument type is not supported"
        end
      end

      def normalize_price(value)
        raise InvalidResponse, "price must not be a float" if value.is_a?(Float)

        price = BigDecimal(value.to_s)
        raise InvalidResponse, "price must be finite and greater than zero" unless price.finite? && price.positive?

        price
      rescue ArgumentError
        raise InvalidResponse, "price is invalid"
      end

      def normalize_currency(value)
        currency = value.to_s.strip.upcase
        raise InvalidResponse, "currency is invalid" unless currency.match?(/\A[A-Z]{3}\z/)

        currency
      end
    end
  end
end
