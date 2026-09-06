module MarketData
  class HealthReport
    class BenchmarkObservations
      def initialize(owner:, today:)
        @owner = owner
        @today = today
      end

      def entries
        MarketBenchmark.find_each.map { |benchmark| entry_for(benchmark) }
      end

      private

      attr_reader :owner, :today

      def entry_for(benchmark)
        required_dates = TradingCalendar.weekdays_between(first_date, historical_end_date)
        observations = benchmark.observations.where(
          observed_on: (HistoricalObservationWindow.for(required_dates.min).begin..historical_end_date)
        ).to_a
        coverage = CoverageCalculator.for(required_dates:, observations:, carry_forward: true)
        present = coverage.complete?
        HealthReport::Entry.new(
          code: present ? :benchmark_data : :missing_benchmark_data,
          target: Target.new(kind: :benchmark_observations, record_id: benchmark.id), subject: benchmark,
          status: present ? :healthy : coverage.partial? ? :partial : :missing,
          severity: present ? nil : :warning, label: subject_label(benchmark),
          description: description(benchmark, coverage), observed_on: nil, fetched_at: nil,
          covered_range: coverage.covered_range, missing_range: coverage.missing_range,
          actions: present ? [] : [ :retry ]
        )
      end

      def first_date
        @first_date ||= owner.trades.minimum(:traded_on) || historical_end_date
      end

      def historical_end_date
        @historical_end_date ||= if TradingCalendar.weekend?(today)
          TradingCalendar.previous_business_day(today + 1.day)
        else
          TradingCalendar.previous_business_day(today)
        end
      end

      def description(benchmark, coverage)
        return "#{benchmark.name} has stored observations." if coverage.complete?

        "#{benchmark.name} (#{benchmark.identifier}) is missing observations for #{format_ranges(coverage.missing_ranges)}."
      end

      def format_ranges(ranges)
        ranges.map { |range| range.begin == range.end ? range.begin.iso8601 : "#{range.begin}–#{range.end}" }.join(", ")
      end

      def subject_label(benchmark)
        "#{benchmark.name} (#{benchmark.identifier})"
      end
    end
  end
end
