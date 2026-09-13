module MarketData
  class HealthReport
    class BenchmarkObservations
      def initialize(owner:, today:, context: nil)
        @owner = owner
        @today = today
        @context = context
      end

      def entries
        MarketBenchmark.find_each.map { |benchmark| entry_for(benchmark) }
      end

      private

      attr_reader :owner, :today, :context

      def entry_for(benchmark)
        importer = MarketBenchmark::Importer.default
        required_dates = importer.expected_dates_for(benchmark:, from: first_date, to: historical_end_date)
        observations = if required_dates.empty?
          []
        else
          benchmark.observations.where(
            observed_on: (HistoricalObservationWindow.for(required_dates.min).begin..historical_end_date)
          ).to_a
        end
        coverage = CoverageCalculator.for(required_dates:, observations:, carry_forward: benchmark.price?)
        present = coverage.complete?
        supported = importer.supports?(benchmark:)
        HealthReport::Entry.new(
          code: present ? :benchmark_data : :missing_benchmark_data,
          target: Target.new(
            kind: :benchmark_observations, record_id: benchmark.id, provider: benchmark.provider
          ), subject: benchmark,
          status: present ? :healthy : supported ? coverage.partial? ? :partial : :missing : :unsupported,
          severity: present ? nil : :warning, label: subject_label(benchmark),
          description: description(benchmark, coverage, supported:), observed_on: nil, fetched_at: nil,
          covered_range: coverage.covered_range, missing_range: coverage.missing_range,
          actions: present || !supported ? [] : [ :retry ]
        )
      end

      def first_date
        @first_date ||= context&.first_trade_date || owner.trades.minimum(:traded_on) || historical_end_date
      end

      def historical_end_date
        @historical_end_date ||= if TradingCalendar.weekend?(today)
          TradingCalendar.previous_business_day(today + 1.day)
        else
          TradingCalendar.previous_business_day(today)
        end
      end

      def description(benchmark, coverage, supported:)
        return "#{benchmark.name} has stored observations." if coverage.complete?
        return "#{benchmark.name} has no configured recovery provider." unless supported

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
