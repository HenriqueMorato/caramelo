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

      def corporate_action_events(identifier:, from:, to:)
        response = transport.get(history_uri(identifier:, from:, to:, events: "div,splits"))
        classify_status!(response)

        parse_corporate_action_events(chart_result(response), identifier:, from:, to:)
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

      def parse_corporate_action_events(result, identifier:, from:, to:)
        validate_identifier!(result.fetch("meta"), identifier)
        events = result["events"] || {}
        raise InvalidResponse, "history events are malformed" unless events.is_a?(Hash)

        dividends = parse_dividends(events["dividends"] || {}, from:, to:)
        splits = parse_splits(events["splits"] || {}, from:, to:)
        dividends + splits
      end

      def parse_dividends(events, from:, to:)
        parse_event_hash(events, from:, to:) do |reference, payload, event_on|
          amount = normalize_event_amount(payload.fetch("amount"))
          CorporateActionEvent.new(
            kind: :dividend, source_reference: reference, event_on:, amount:,
            ratio_numerator: nil, ratio_denominator: nil, raw_payload: payload
          )
        end
      end

      def parse_splits(events, from:, to:)
        parse_event_hash(events, from:, to:) do |reference, payload, event_on|
          numerator, denominator = normalize_split_ratio(payload)
          kind = numerator > denominator ? :split : :reverse_split
          CorporateActionEvent.new(
            kind:, source_reference: reference, event_on:, amount: nil,
            ratio_numerator: numerator, ratio_denominator: denominator, raw_payload: payload
          )
        end
      end

      def parse_event_hash(events, from:, to:)
        raise InvalidResponse, "history events are malformed" unless events.is_a?(Hash)

        events.filter_map do |reference, payload|
          raise InvalidResponse, "history event is malformed" unless payload.is_a?(Hash)

          event_on = event_date(payload, reference)
          next unless event_on.between?(from, to)

          yield reference.to_s, payload, event_on
        end
      end

      def event_date(payload, reference)
        timestamp = payload["date"] || payload["timestamp"] || reference
        Time.at(Integer(timestamp)).utc.to_date
      rescue ArgumentError, TypeError
        raise InvalidResponse, "event date is invalid"
      end

      def normalize_event_amount(value)
        raise InvalidResponse, "event amount must not be a float" if value.is_a?(Float)

        amount = BigDecimal(value.to_s)
        raise InvalidResponse, "event amount is invalid" unless amount.finite? && amount.positive?

        amount
      rescue ArgumentError
        raise InvalidResponse, "event amount is invalid"
      end

      def normalize_split_ratio(payload)
        ratio = payload["splitRatio"].to_s
        numerator, denominator = ratio.split(":", 2)
        numerator ||= payload["numerator"]
        denominator ||= payload["denominator"]
        numerator = Integer(numerator)
        denominator = Integer(denominator)
        raise InvalidResponse, "split ratio is invalid" unless numerator.positive? && denominator.positive?

        [ numerator, denominator ]
      rescue ArgumentError, TypeError
        raise InvalidResponse, "split ratio is invalid"
      end

      DailyClose = Data.define(:close_price, :currency, :trading_date, :observed_at)
      CorporateActionEvent = Data.define(
        :kind, :source_reference, :event_on, :amount, :ratio_numerator, :ratio_denominator, :raw_payload
      ) do
        def dividend? = kind.to_s == "dividend"
      end
    end
  end
end
