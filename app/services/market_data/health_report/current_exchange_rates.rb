module MarketData
  class HealthReport
    class CurrentExchangeRates
      def initialize(context:, service:)
        @context = context
        @service = service
      end

      def entries
        foreign_currencies.map { |currency| entry_for(currency) }
      end

      private

      attr_reader :context, :service

      delegate :owner, :instruments, to: :context

      def entry_for(currency)
        lookup = service.read(base_currency: currency, quote_currency: owner.reporting_currency)
        status = lookup.fresh? ? :healthy : lookup.stale? ? :stale : :missing
        present = status == :healthy
        build(
          code: present ? :current_exchange_rate : :missing_current_exchange_rate,
          status:, severity: present ? nil : :warning, subject: currency,
          description: current_description(currency:, status:),
          target: Target.new(kind: :current_exchange_rate,
            base_currency: currency, quote_currency: owner.reporting_currency,
            provider: MarketData::YahooFinance::FX_CONFIGURATION.identifier),
          actions: present ? [] : [ :retry ]
        )
      end

      def foreign_currencies
        @foreign_currencies ||= instruments.filter_map do |instrument|
          next unless instrument.currency != owner.reporting_currency && Position.for(instrument:).open?

          instrument.currency
        end.uniq
      end

      def current_description(currency:, status:)
        pair = "#{currency}/#{owner.reporting_currency}"
        return "Current #{pair} exchange rate is available." if status == :healthy
        return "Current #{pair} exchange rate is stale; refresh it to update valuation." if status == :stale

        "Current #{pair} exchange rate is unavailable."
      end

      def build(code:, target:, subject:, status:, severity:, description:, actions:, coverage: nil)
        HealthReport::Entry.new(
          code:, target:, subject:, status:, severity:, label: subject.to_s, description:,
          observed_on: nil, fetched_at: nil, covered_range: coverage&.covered_range,
          missing_range: coverage&.missing_range, actions:
        )
      end
    end
  end
end
