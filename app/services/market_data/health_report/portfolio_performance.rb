module MarketData
  class HealthReport
    class PortfolioPerformance
      def initialize(owner:, today:, context: nil)
        @owner = owner
        @today = today
        @context = context
      end

      def entries
        materialization = PortfolioPerformanceMaterialization.find_by(
          user: owner, reporting_currency: owner.reporting_currency
        )
        return [] unless materialization

        first_date = context&.first_performance_date || Context.new(owner:, today:).first_performance_date
        return [] unless first_date

        required_dates = (first_date..today).to_a
        observations = owner.portfolio_performance_observations.where(
          reporting_currency: owner.reporting_currency, observed_on: (first_date..today)
        ).to_a.reject(&:missing?)
        coverage = CoverageCalculator.for(required_dates:, observations:)
        refresh = Performance::SeriesRefresh.read(user: owner, reporting_currency: owner.reporting_currency)
        status = status_for(materialization, coverage, refresh)
        [ build(status:, coverage:) ]
      end

      private

      attr_reader :owner, :today, :context

      def status_for(materialization, coverage, refresh)
        return :failed if materialization.pending? && refresh&.failed?
        return :updating if materialization.pending?
        return :healthy if coverage.complete?
        return :partial if coverage.partial?

        :missing
      end

      def build(status:, coverage:)
        severity = :error if status == :failed
        severity ||= :warning if %i[missing partial].include?(status)
        HealthReport::Entry.new(
          code: :portfolio_performance, status:, severity:,
          subject: "Portfolio performance", label: "Portfolio performance",
          description: description(status:, coverage:),
          target: Target.new(kind: :portfolio_performance, quote_currency: owner.reporting_currency),
          actions: status == :healthy ? [] : [ :retry ], observed_on: nil, fetched_at: nil,
          covered_range: coverage.covered_range, missing_range: coverage.missing_range
        )
      end

      def description(status:, coverage:)
        return "Portfolio performance failed to rebuild." if status == :failed
        return "Portfolio performance is up to date." if coverage.complete?

        "Portfolio performance is missing values for #{format_ranges(coverage.missing_ranges)}."
      end

      def format_ranges(ranges)
        ranges.map { |range| range.begin == range.end ? range.begin.iso8601 : "#{range.begin}–#{range.end}" }.join(", ")
      end
    end
  end
end
