module MarketData
  class HealthReport
    class PortfolioPerformance
      def initialize(owner:, today:)
        @owner = owner
        @today = today
      end

      def entries
        materialization = PortfolioPerformanceMaterialization.find_by(
          user: owner, reporting_currency: owner.reporting_currency
        )
        return [] unless materialization

        first_date = owner.trades.minimum(:traded_on)
        return [] unless first_date

        required_dates = (first_date..today).to_a
        observations = owner.portfolio_performance_observations.where(
          reporting_currency: owner.reporting_currency, observed_on: (first_date..today)
        ).to_a
        coverage = CoverageCalculator.for(required_dates:, observations:)
        status = status_for(materialization, coverage)
        [ build(status:, coverage:) ]
      end

      private

      attr_reader :owner, :today

      def status_for(materialization, coverage)
        return :updating if materialization.pending?
        return :healthy if coverage.complete?
        return :partial if coverage.partial?

        :missing
      end

      def build(status:, coverage:)
        HealthReport::Entry.new(
          code: :portfolio_performance, status:, severity: %i[missing partial].include?(status) ? :warning : nil,
          subject: "Portfolio performance", label: "Portfolio performance",
          description: description(coverage), target: Target.new(kind: :portfolio_performance),
          actions: status == :healthy ? [] : [ :retry ], observed_on: nil, fetched_at: nil,
          covered_range: coverage.covered_range, missing_range: coverage.missing_range
        )
      end

      def description(coverage)
        return "Portfolio performance is up to date." if coverage.complete?

        "Portfolio performance is missing values for #{format_ranges(coverage.missing_ranges)}."
      end

      def format_ranges(ranges)
        ranges.map { |range| range.begin == range.end ? range.begin.iso8601 : "#{range.begin}–#{range.end}" }.join(", ")
      end
    end
  end
end
