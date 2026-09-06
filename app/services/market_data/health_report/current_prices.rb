module MarketData
  class HealthReport
    class CurrentPrices
      def initialize(instruments:, service:)
        @instruments = instruments
        @service = service
      end

      def entries
        instruments.map { |instrument| entry_for(instrument) }
      end

      private

      attr_reader :instruments, :service

      def entry_for(instrument)
        lookup = service.read(instrument:)
        refresh_state = RefreshStatus::State.read("current_market_price:#{instrument.id}")
        if refresh_state&.interrupted?
          build(instrument, :interrupted_current_price, :interrupted, :error,
            "#{instrument.ticker} refresh stopped before completing.")
        elsif refresh_state&.failed?
          build(instrument, :failed_current_price, :failed, :error,
            refresh_state.error_message.presence || "#{instrument.ticker} refresh failed.")
        elsif refreshing?(refresh_state)
          build(instrument, :updating_current_price, :updating, nil,
            "#{instrument.ticker} is being refreshed.", actions: [])
        elsif lookup.nil? || lookup.missing?
          build(instrument, :missing_current_price, :missing, :error,
            "#{instrument.ticker} has no current market price available.")
        elsif lookup.stale?
          build(instrument, :stale_current_price, :stale, :warning,
            "#{instrument.ticker} has a stale current market price; refresh it to update valuation.")
        else
          build(instrument, :current_price, :healthy, nil,
            "#{instrument.ticker} has a current market price.", actions: [])
        end
      end

      def build(instrument, code, status, severity, description, actions: [ :retry ])
        HealthReport::Entry.new(
          code:, target: current_price_target(instrument), subject: instrument, status:, severity:,
          label: "#{instrument.ticker} · #{instrument.name}", description:, observed_on: nil,
          fetched_at: nil, covered_range: nil, missing_range: nil, actions:
        )
      end

      def current_price_target(instrument)
        Target.new(
          kind: :current_price, record_id: instrument.id,
          provider: MarketData::YahooFinance::MARKET_CONFIGURATION.identifier
        )
      end

      def refreshing?(state)
        state&.active? && !state.interrupted?
      end
    end
  end
end
