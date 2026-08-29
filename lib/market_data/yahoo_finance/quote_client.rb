module MarketData
  module YahooFinance
    class QuoteClient < BaseClient
      def quote(identifier)
        response = transport.get(chart_uri(identifier))
        classify_status!(response)
        parse_quote(response, identifier)
      end

      private
      def parse_quote(response, identifier)
        quote_from(chart_result(response) { |error, current_response| raise_chart_error!(error, current_response) }.fetch("meta"), identifier)
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
        validate_identifier!(meta, identifier)
        symbol = meta.fetch("symbol")
        provider_exchange = meta.fetch("exchangeName")
        instrument_type = meta.fetch("instrumentType")

        unit_price, currency, provider_currency = normalize_amount(
          price: meta.fetch("regularMarketPrice"),
          currency: meta.fetch("currency")
        )

        Quote.new(
          symbol:,
          unit_price:,
          currency:,
          quoted_at: Time.at(Integer(meta.fetch("regularMarketTime"))).utc,
          provider_exchange:,
          instrument_type:,
          provider_currency:
        )
      end

      def normalize_amount(price:, currency:)
        unit_price = normalize_price(price)
        provider_currency = currency.to_s.strip

        # Yahoo uses GBp (and sometimes GBX) for prices quoted in pence.
        return [ unit_price / 100, "GBP", provider_currency ] if %w[GBp GBX].include?(provider_currency)

        [ unit_price, normalize_currency(provider_currency), provider_currency ]
      end
    end
  end
end
