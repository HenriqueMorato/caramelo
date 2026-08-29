module MarketData
  module YahooFinance
    class FxClient < BaseClient
      def rate(base_currency:, quote_currency:)
        pair = CurrencyPair.new(base_currency:, quote_currency:)

        response = transport.get(chart_uri_for(value: pair.symbol))
        classify_status!(response)

        meta = chart_result(response, expected: "expected exactly one FX result").fetch("meta")
        rate = normalize_price(meta.fetch("regularMarketPrice"))
        currency = normalize_currency(meta.fetch("currency"))
        raise InvalidResponse, "FX response currency does not match quote" unless currency == pair.quote_currency

        Rate.new(rate:, observed_at: Time.at(Integer(meta.fetch("regularMarketTime"))).utc)
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
        raise InvalidResponse, error.message
      end

      Rate = Data.define(:rate, :observed_at)

      private
    end
  end
end
