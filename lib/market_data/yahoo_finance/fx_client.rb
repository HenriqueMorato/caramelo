module MarketData
  module YahooFinance
    class FxClient < BaseClient
      def rate(base_currency:, quote_currency:)
        base_currency = normalize_request_currency(base_currency)
        quote_currency = normalize_request_currency(quote_currency)
        raise ArgumentError, "currencies must differ" if base_currency == quote_currency

        response = transport.get(chart_uri_for(value: "#{base_currency}#{quote_currency}=X"))
        classify_status!(response)

        payload = JSON.parse(response.body, decimal_class: BigDecimal)
        results = payload.fetch("chart").fetch("result")
        raise InvalidResponse, "expected exactly one FX result" unless results.is_a?(Array) && results.one?

        meta = results.first.fetch("meta")
        rate = normalize_price(meta.fetch("regularMarketPrice"))
        currency = normalize_currency(meta.fetch("currency"))
        raise InvalidResponse, "FX response currency does not match quote" unless currency == quote_currency

        Rate.new(rate:, observed_at: Time.at(Integer(meta.fetch("regularMarketTime"))).utc)
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
        raise InvalidResponse, error.message
      end

      Rate = Data.define(:rate, :observed_at)

      private

      def normalize_request_currency(value)
        currency = value.to_s.strip.upcase
        raise ArgumentError, "currency is invalid" unless currency.match?(/\A[A-Z]{3}\z/) && Money::Currency.find(currency)

        currency
      end
    end
  end
end
