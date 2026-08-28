module MarketData
  module YahooFinance
    class Client
      ENDPOINT_PATH = "/v8/finance/chart"
      SUCCESS_RANGE = 200..299

      def initialize(transport:)
        @transport = transport
      end

      def quote(identifier)
        response = transport.get(chart_uri(identifier))
        classify_status!(response)
        parse_quote(response, identifier)
      end

      private

      attr_reader :transport

      def chart_uri(identifier)
        URI::HTTPS.build(
          host: CurlTransport::ALLOWED_HOST,
          path: "#{ENDPOINT_PATH}/#{identifier.value}",
          query: URI.encode_www_form(range: "1d", interval: "1d")
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

      def parse_quote(response, identifier)
        payload = JSON.parse(response.body, decimal_class: BigDecimal)
        chart = payload.fetch("chart")
        raise_chart_error!(chart.fetch("error"), response) if chart["error"]

        results = chart.fetch("result")
        raise InvalidResponse, "expected exactly one chart result" unless results.is_a?(Array) && results.one?

        quote_from(results.first.fetch("meta"), identifier)
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
        raise InvalidResponse, error.message
      end

      def raise_chart_error!(error, response)
        message = error.is_a?(Hash) ? error["description"] || error["code"] : error.to_s
        if error.is_a?(Hash) && error["code"] == "Not Found"
          raise SymbolNotFound.new(status: response.status, headers: response.headers, message:)
        end

        raise InvalidResponse, message
      end

      def quote_from(meta, identifier)
        symbol = meta.fetch("symbol")
        raise InvalidResponse, "response symbol does not match request" unless symbol == identifier.value

        provider_exchange = meta.fetch("exchangeName")
        unless identifier.matches_provider_exchange?(provider_exchange)
          raise InvalidResponse, "response exchange does not match request"
        end

        instrument_type = meta.fetch("instrumentType")
        unless identifier.supports_instrument_type?(instrument_type)
          raise InvalidResponse, "response instrument type is not supported"
        end

        Quote.new(
          symbol:,
          unit_price: normalize_price(meta.fetch("regularMarketPrice")),
          currency: normalize_currency(meta.fetch("currency")),
          quoted_at: Time.at(Integer(meta.fetch("regularMarketTime"))).utc,
          provider_exchange:,
          instrument_type:
        )
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
