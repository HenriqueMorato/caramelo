module MarketData
  module YahooFinance
    class FxHistoryClient < BaseClient
      Rate = Data.define(:rate, :rate_date, :observed_at)

      def daily_rates(base_currency:, quote_currency:, from:, to:)
        base_currency = normalize_request_currency(base_currency)
        quote_currency = normalize_request_currency(quote_currency)
        raise ArgumentError, "currencies must differ" if base_currency == quote_currency

        validate_range!(from:, to:)
        begin
          response = transport.get(history_uri_for(value: "#{base_currency}#{quote_currency}=X", from:, to:))
          classify_status!(response)

          payload = JSON.parse(response.body, decimal_class: BigDecimal)
          chart = payload.fetch("chart")
          raise_chart_error!(chart.fetch("error")) if chart["error"]

          results = chart.fetch("result")
          raise InvalidResponse, "expected exactly one FX history result" unless results.is_a?(Array) && results.one?

          parse_rates(results.first, base_currency:, quote_currency:)
        rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
          raise InvalidResponse, error.message
        end
      end

      private

      def validate_range!(from:, to:)
        raise ArgumentError, "history range must be on or before today" if from > to || to > Date.current
      end

      def parse_rates(result, base_currency:, quote_currency:)
        meta = result.fetch("meta")
        expected_symbol = "#{base_currency}#{quote_currency}=X"
        raise InvalidResponse, "response symbol does not match request" unless meta.fetch("symbol") == expected_symbol
        raise InvalidResponse, "FX response currency does not match quote" unless normalize_currency(meta.fetch("currency")) == quote_currency

        timestamps = result.fetch("timestamp")
        quotes = result.fetch("indicators").fetch("quote")
        unless quotes.is_a?(Array) && quotes.one? && quotes.first.is_a?(Hash)
          raise InvalidResponse, "FX history quote data is malformed"
        end

        closes = quotes.first.fetch("close")
        raise InvalidResponse, "FX history timestamps and closes differ in length" unless timestamps.length == closes.length

        timestamps.zip(closes).filter_map do |timestamp, close|
          next if close.nil?

          observed_at = Time.at(Integer(timestamp)).utc
          Rate.new(rate: normalize_rate(close), rate_date: observed_at.to_date, observed_at:)
        end
      end

      def normalize_rate(value)
        raise InvalidResponse, "FX rate must not be a float" if value.is_a?(Float)

        rate = BigDecimal(value.to_s)
        raise InvalidResponse, "FX rate must be finite and positive" unless rate.finite? && rate.positive?

        rate
      rescue ArgumentError
        raise InvalidResponse, "FX rate is invalid"
      end

      def normalize_currency(value)
        super
      end

      def normalize_request_currency(value)
        currency = value.to_s.strip.upcase
        raise ArgumentError, "currency is invalid" unless currency.match?(/\A[A-Z]{3}\z/) && Money::Currency.find(currency)

        currency
      end

      def raise_chart_error!(error)
        message = error.is_a?(Hash) ? error["description"] || error["code"] : error.to_s
        raise InvalidResponse, message
      end
    end
  end
end
