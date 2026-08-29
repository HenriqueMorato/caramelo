module MarketData
  module YahooFinance
    class FxHistoryClient < BaseClient
      Rate = Data.define(:rate, :rate_date, :observed_at)

      def daily_rates(base_currency:, quote_currency:, from:, to:)
        pair = CurrencyPair.new(base_currency:, quote_currency:)

        validate_range!(from:, to:)
        begin
          response = transport.get(history_uri_for(value: pair.symbol, from:, to:))
          classify_status!(response)

          parse_rates(chart_result(response, expected: "expected exactly one FX history result"), base_currency: pair.base_currency, quote_currency: pair.quote_currency)
        rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
          raise InvalidResponse, error.message
        end
      end

      private

      def validate_range!(from:, to:)
        raise ArgumentError, "history range must be on or before today" if from > to || to > Date.current
      end

      def parse_rates(result, base_currency:, quote_currency:)
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

          # Yahoo's daily candle timestamp is interpreted in UTC, matching the
          # existing daily closing-price importer and keeping date derivation stable.
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
    end
  end
end
