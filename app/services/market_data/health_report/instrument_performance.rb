module MarketData
  class HealthReport
    class InstrumentPerformance
      def initialize(owner:, today:, context: nil)
        @owner = owner
        @today = today
        @context = context
      end

      def entries
        instruments.flat_map do |instrument|
          currencies_for(instrument).filter_map { |currency| entry_for(instrument:, currency:) }
        end
      end

      private

      attr_reader :owner, :today, :context

      def instruments
        context&.instruments || owner.trades.includes(:instrument).map(&:instrument).uniq
      end

      def currencies_for(instrument)
        materialized = owner.instrument_performance_materializations.where(instrument:).pluck(:reporting_currency)
        (materialized + [ instrument.currency, owner.reporting_currency ]).uniq
      end

      def entry_for(instrument:, currency:)
        first_date = owner.trades.where(instrument:).minimum(:traded_on)
        materialization = InstrumentPerformanceMaterialization.find_by(
          user: owner, instrument:, reporting_currency: currency
        )
        return unless materialization

        observations = owner.instrument_performance_observations.where(
          instrument:, reporting_currency: currency, observed_on: first_date..today
        ).to_a
        coverage = CoverageCalculator.for(required_dates: (first_date..today).to_a, observations:)
        refresh = Performance::SeriesRefresh.read(user: owner, instrument:, reporting_currency: currency)
        status = status_for(materialization:, observations:, coverage:, refresh:)
        build(instrument:, currency:, status:, coverage:)
      end

      def status_for(materialization:, observations:, coverage:, refresh:)
        return :failed if refresh&.failed?
        return :updating if materialization.pending? || refresh&.active?
        return :stale if observations.any?(&:stale?)
        return :healthy if coverage.complete?
        return :partial if coverage.partial?

        :missing
      end

      def build(instrument:, currency:, status:, coverage:)
        severity = :error if status == :failed
        severity ||= :warning if %i[missing partial stale].include?(status)
        HealthReport::Entry.new(
          code: :instrument_performance,
          status:,
          severity:,
          subject: instrument,
          label: "#{instrument.ticker} performance · #{currency}",
          description: description(instrument:, currency:, status:, coverage:),
          target: Target.new(kind: :instrument_performance, record_id: instrument.id, quote_currency: currency),
          actions: %i[healthy updating].include?(status) ? [] : [ :retry ],
          observed_on: nil,
          fetched_at: nil,
          covered_range: coverage.covered_range,
          missing_range: coverage.missing_range
        )
      end

      def description(instrument:, currency:, status:, coverage:)
        return "#{instrument.ticker} performance in #{currency} is up to date." if status == :healthy
        return "#{instrument.ticker} performance in #{currency} is rebuilding." if status == :updating
        return "#{instrument.ticker} performance in #{currency} failed to rebuild." if status == :failed
        return "#{instrument.ticker} performance in #{currency} has stale last-known values." if status == :stale

        "#{instrument.ticker} performance in #{currency} is missing values for #{format_ranges(coverage.missing_ranges)}."
      end

      def format_ranges(ranges)
        ranges.map { |range| range.begin == range.end ? range.begin.iso8601 : "#{range.begin}–#{range.end}" }.join(", ")
      end
    end
  end
end
