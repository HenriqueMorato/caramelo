module MarketData
  module YahooFinance
    class HistoryClient < BaseClient
      def daily_closes(identifier:, from:, to:)
        response = transport.get(history_uri(identifier:, from:, to:))
        classify_status!(response)

        parse_daily_closes(chart_result(response), identifier:)
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
        raise InvalidResponse, error.message
      end

      private

      def parse_daily_closes(result, identifier:)
        meta = result.fetch("meta")
        validate_identifier!(meta, identifier)
        currency = normalize_currency(meta.fetch("currency"))
        timestamps = result.fetch("timestamp")
        quotes = result.fetch("indicators").fetch("quote")
        unless quotes.is_a?(Array) && quotes.one? && quotes.first.is_a?(Hash)
          raise InvalidResponse, "history quote data is malformed"
        end

        closes = quotes.first.fetch("close")
        raise InvalidResponse, "history timestamps and closes differ in length" unless timestamps.length == closes.length

        timestamps.zip(closes).filter_map do |timestamp, close|
          next if close.nil?

          price = normalize_price(close)
          observed_at = Time.at(Integer(timestamp)).utc
          DailyClose.new(close_price: price, currency:, trading_date: observed_at.to_date, observed_at:)
        end
      end

      DailyClose = Data.define(:close_price, :currency, :trading_date, :observed_at)
    end
  end
end
