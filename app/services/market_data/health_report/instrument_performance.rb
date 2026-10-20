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
        health_context.performance_instruments
      end

      def currencies_for(instrument)
        materialized = owner.instrument_performance_materializations.where(instrument:).pluck(:reporting_currency)
        (materialized + [ instrument.currency, owner.reporting_currency ]).uniq
      end

      def entry_for(instrument:, currency:)
        first_date = health_context.first_performance_date_for(instrument)
        materialization = InstrumentPerformanceMaterialization.find_by(
          user: owner, instrument:, reporting_currency: currency
        )
        return unless materialization

        observations = owner.instrument_performance_observations.where(
          instrument:, reporting_currency: currency, observed_on: first_date..today
        ).to_a.reject(&:missing?)
        coverage = CoverageCalculator.for(required_dates: (first_date..today).to_a, observations:)
        refresh = Performance::SeriesRefresh.read(user: owner, instrument:, reporting_currency: currency)
        status = status_for(materialization:, observations:, coverage:, refresh:)
        build(instrument:, currency:, status:, coverage:, refresh:)
      end

      def status_for(materialization:, observations:, coverage:, refresh:)
        return :failed if materialization.pending? && refresh&.failed?
        return :interrupted if materialization.pending? && refresh&.interrupted?
        return :updating if materialization.pending?
        return :stale if observations.any?(&:stale?)
        return :healthy if coverage.complete?
        return :partial if coverage.partial?

        :missing
      end

      def build(instrument:, currency:, status:, coverage:, refresh:)
        severity = :error if status == :failed
        severity ||= :error if status == :interrupted
        severity ||= :warning if %i[missing partial stale].include?(status)
        HealthReport::Entry.new(
          code: :instrument_performance,
          status:,
          severity:,
          subject: instrument,
          label: "#{instrument.ticker} performance · #{currency}",
          description: description(instrument:, currency:, status:, coverage:, refresh:),
          target: Target.new(kind: :instrument_performance, record_id: instrument.id, quote_currency: currency),
          actions: %i[healthy updating].include?(status) ? [] : [ :retry ],
          observed_on: nil,
          fetched_at: nil,
          covered_range: coverage.covered_range,
          missing_range: coverage.missing_range
        )
      end

      def description(instrument:, currency:, status:, coverage:, refresh:)
        return "#{instrument.ticker} performance in #{currency} is up to date." if status == :healthy
        if status == :updating
          return "#{instrument.ticker} performance in #{currency} is fetching historical prices and exchange rates." if refresh&.phase == "fetching"

          return "#{instrument.ticker} performance in #{currency} is rebuilding."
        end
        if status == :failed
          message = refresh.error_message
          return "#{instrument.ticker} performance in #{currency} could not rebuild: #{message}" if dependency_error?(message)

          return "#{instrument.ticker} performance in #{currency} failed to rebuild."
        end
        return "#{instrument.ticker} performance in #{currency} refresh stopped before completing." if status == :interrupted
        return "#{instrument.ticker} performance in #{currency} has stale last-known values." if status == :stale

        "#{instrument.ticker} performance in #{currency} is missing values for #{format_ranges(coverage.missing_ranges)}."
      end

      def dependency_error?(message)
        message.to_s.start_with?("Historical data remains unavailable:")
      end

      def format_ranges(ranges)
        ranges.map { |range| range.begin == range.end ? range.begin.iso8601 : "#{range.begin}–#{range.end}" }.join(", ")
      end

      def health_context
        @health_context ||= context || Context.new(owner:, today:)
      end
    end
  end
end
