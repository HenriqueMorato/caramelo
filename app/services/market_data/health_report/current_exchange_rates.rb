module MarketData
  class HealthReport
    class CurrentExchangeRates
      def initialize(owner:, instruments:, service:)
        @owner = owner
        @instruments = instruments
        @service = service
      end

      def entries
        current_entries + historical_entries
      end

      private

      attr_reader :owner, :instruments, :service

      def current_entries
        foreign_currencies.map do |currency|
          lookup = service.read(base_currency: currency, quote_currency: owner.reporting_currency)
          status = lookup.fresh? ? :healthy : lookup.stale? ? :stale : :missing
          present = status == :healthy
          build(
            code: present ? :current_exchange_rate : :missing_current_exchange_rate,
            status:, severity: present ? nil : :warning, subject: currency,
            description: current_description(currency:, status:),
            target: Target.new(kind: :current_exchange_rate,
              base_currency: currency, quote_currency: owner.reporting_currency),
            actions: present ? [] : [ :retry ]
          )
        end
      end

      def historical_entries
        owner.trades.distinct.pluck(:currency).map do |currency|
          required_dates = historical_rate_dates(currency)
          observations = observations_for(currency, required_dates)
          coverage = if currency == owner.reporting_currency
            CoverageCalculator.for(
              required_dates:, observations: required_dates.map { |date| HistoricalExchangeRate.new(rate_date: date) }
            )
          else
            CoverageCalculator.for(required_dates:, observations:, carry_forward: true)
          end
          present = coverage.complete?
          build(
            code: present ? :exchange_rate : :missing_exchange_rate,
            status: present ? :healthy : coverage.partial? ? :partial : :missing,
            severity: present ? nil : :warning, subject: currency,
            description: historical_description(currency:, coverage:),
            target: Target.new(kind: :historical_exchange_rates,
              base_currency: currency, quote_currency: owner.reporting_currency),
            actions: present ? [] : [ :retry ], coverage:
          )
        end
      end

      def observations_for(currency, required_dates)
        return [] if required_dates.empty?

        query_range = HistoricalObservationWindow.for(required_dates.min).begin..required_dates.max
        direct = HistoricalExchangeRate.where(
          base_currency: currency, quote_currency: owner.reporting_currency, rate_date: query_range
        )
        inverse = HistoricalExchangeRate.where(
          base_currency: owner.reporting_currency, quote_currency: currency, rate_date: query_range
        )
        (direct.to_a + inverse.to_a)
      end

      def historical_rate_dates(currency)
        owner.trades.where(currency:).distinct.order(:traded_on).pluck(:traded_on).map do |date|
          TradingCalendar.weekend?(date) ? TradingCalendar.previous_business_day(date + 1.day) : date
        end.uniq
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

      def historical_description(currency:, coverage:)
        return "Historical #{currency}/#{owner.reporting_currency} rates are available." if coverage.complete?

        "Historical #{currency}/#{owner.reporting_currency} rates are missing for #{format_ranges(coverage.missing_ranges)}."
      end

      def format_ranges(ranges)
        ranges.map { |range| range.begin == range.end ? range.begin.iso8601 : "#{range.begin}–#{range.end}" }.join(", ")
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
