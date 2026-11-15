module MarketData
  module YahooFinance
    class FxHistoryClient < BaseClient
      Rate = Data.define(:rate, :rate_date, :observed_at)

      def daily_rates(base_currency:, quote_currency:, from:, to:)
        pair = CurrencyPair.new(base_currency:, quote_currency:)

        validate_range!(from:, to:)
        begin
          response = transport.get(
            history_uri_for(value: pair.symbol, from:, to: request_to(to))
          )
          classify_status!(response)

          parse_rates(
            chart_result(response, expected: "expected exactly one FX history result"),
            base_currency: pair.base_currency, quote_currency: pair.quote_currency, from:, to:
          )
        rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
          raise InvalidResponse, error.message
        end
      end

      private

      def validate_range!(from:, to:)
        raise ArgumentError, "history range must be on or before today" if from > to || to > Date.current
      end

      def parse_rates(result, base_currency:, quote_currency:, from:, to:)
        raise InvalidResponse, "FX history result is malformed" unless result.is_a?(Hash)

        meta = result.fetch("meta")
        expected_symbol = "#{base_currency}#{quote_currency}=X"
        raise InvalidResponse, "response symbol does not match request" unless meta.fetch("symbol") == expected_symbol
        raise InvalidResponse, "FX response currency does not match quote" unless normalize_currency(meta.fetch("currency")) == quote_currency

        timestamps = result.fetch("timestamp")
        raise InvalidResponse, "FX history timestamps are malformed" unless timestamps.is_a?(Array)
        quotes = result.fetch("indicators").fetch("quote")
        unless quotes.is_a?(Array) && quotes.one? && quotes.first.is_a?(Hash)
          raise InvalidResponse, "FX history quote data is malformed"
        end

        closes = quotes.first.fetch("close")
        raise InvalidResponse, "FX history closes are malformed" unless closes.is_a?(Array)
        raise InvalidResponse, "FX history timestamps and closes differ in length" unless timestamps.length == closes.length

        timestamps.zip(closes).filter_map do |timestamp, close|
          next if close.nil?

          observed_at = Time.at(Integer(timestamp)).utc
          rate_date = rate_date_for(observed_at)
          next unless (from..to).cover?(rate_date)

          rate = normalize_rate(close)
          Rate.new(rate:, rate_date:, observed_at:)
        end
      end

      def rate_date_for(observed_at)
        # Yahoo labels the FX candle covering Friday with a Sunday UTC timestamp
        # because the currency market reopens then. Move weekend labels back to
        # the preceding business day so Friday does not remain perpetually missing.
        date = observed_at.to_date
        date -= 1.day while date.saturday? || date.sunday?
        date
      end

      def request_to(date)
        # A Friday candle can be labelled Sunday by Yahoo, so include the
        # following Sunday before BaseClient adds its exclusive day.
        date + 2.days
      end

      def normalize_rate(value)
        DecimalNormalizer.positive(
          value:, float_message: "FX rate must not be a float",
          invalid_message: "FX rate is invalid", nonpositive_message: "FX rate must be finite and positive"
        )
      end
    end
  end
end
