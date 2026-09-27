module CorporateActionImports
  module Providers
    class YahooFinance
      IDENTIFIER = MarketData::YahooFinance::MARKET_CONFIGURATION.identifier

      def initialize(client: default_client)
        @client = client
      end

      def identifier = IDENTIFIER

      def fetch(instrument:, from:, to:)
        return [] unless MarketData::YahooFinance::Identifier.supports_mic?(instrument.exchange)

        yahoo_identifier = MarketData::YahooFinance::Identifier.build(
          ticker: instrument.ticker, mic: instrument.exchange
        )
        client.corporate_action_events(identifier: yahoo_identifier, from:, to:).map do |event|
          CorporateActionImports::Candidate.new(
            kind: event.kind.to_s,
            source_reference: "#{yahoo_identifier.value}:#{provider_event_kind(event)}:#{event.source_reference}",
            event_on: event.event_on,
            amount_per_share: event.amount,
            ratio_numerator: event.ratio_numerator,
            ratio_denominator: event.ratio_denominator,
            currency: instrument.currency,
            provider_symbol: yahoo_identifier.value,
            provider_exchange: instrument.exchange,
            raw_payload: event.raw_payload,
            warnings: warnings_for(event)
          )
        end
      end

      private

      attr_reader :client

      def default_client
        MarketData::YahooFinance::HistoryClient.new(
          transport: MarketData::YahooFinance::CurlTransport.from_configuration(
            MarketData::YahooFinance::MARKET_CONFIGURATION
          )
        )
      end

      def warnings_for(event)
        return %w[payment_date_required gross_amount_requires_review] if event.dividend?

        []
      end

      def provider_event_kind(event)
        event.dividend? ? "dividend" : "split"
      end
    end
  end
end
