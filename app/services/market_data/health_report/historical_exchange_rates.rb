module MarketData
  class HealthReport
    class HistoricalExchangeRates
      def initialize(owner:)
        @owner = owner
      end

      def entries
        owner.trades.distinct.pluck(:currency).map { |currency| entry_for(currency) }
      end

      private

      attr_reader :owner

      def entry_for(currency)
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
        HealthReport::Entry.new(
          code: present ? :exchange_rate : :missing_exchange_rate,
          status: present ? :healthy : coverage.partial? ? :partial : :missing,
          severity: present ? nil : :warning, subject: currency, label: currency,
          description: description(currency:, coverage:),
          target: Target.new(kind: :historical_exchange_rates,
            base_currency: currency, quote_currency: owner.reporting_currency),
          actions: present ? [] : [ :retry ], observed_on: nil, fetched_at: nil,
          covered_range: coverage.covered_range, missing_range: coverage.missing_range
        )
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
        direct.to_a + inverse.to_a
      end

      def historical_rate_dates(currency)
        owner.trades.where(currency:).distinct.order(:traded_on).pluck(:traded_on).map do |date|
          TradingCalendar.weekend?(date) ? TradingCalendar.previous_business_day(date + 1.day) : date
        end.uniq
      end

      def description(currency:, coverage:)
        return "Historical #{currency}/#{owner.reporting_currency} rates are available." if coverage.complete?

        "Historical #{currency}/#{owner.reporting_currency} rates are missing for #{format_ranges(coverage.missing_ranges)}."
      end

      def format_ranges(ranges)
        ranges.map { |range| range.begin == range.end ? range.begin.iso8601 : "#{range.begin}–#{range.end}" }.join(", ")
      end
    end
  end
end
