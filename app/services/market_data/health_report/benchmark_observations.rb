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
        end_date = importer.available_through_for(benchmark:, on: today) || historical_end_date
        start_date = first_date(benchmark:, end_date:, importer:)
        required_dates = if start_date && start_date <= end_date
          importer.expected_dates_for(benchmark:, from: start_date, to: end_date)
        else
          []
        end
        observations = if required_dates.empty?
          []
        else
          benchmark.observations.where(
            observed_on: (HistoricalObservationWindow.for(required_dates.min).begin..end_date)
          ).to_a
        end
        coverage = CoverageCalculator.for(required_dates:, observations:, carry_forward: benchmark.index?)
        supported = importer.supports?(benchmark:)
        status = status_for(benchmark:, coverage:, supported:, end_date:)
        present = status == :healthy
        HealthReport::Entry.new(
          code: present ? :benchmark_data : :missing_benchmark_data,
          target: Target.new(
            kind: :benchmark_observations, record_id: benchmark.id, provider: benchmark.provider
          ), subject: benchmark,
          status:,
          severity: present ? nil : :warning, label: subject_label(benchmark),
          description: description(benchmark, coverage, supported:, status:, end_date:), observed_on: nil, fetched_at: nil,
          covered_range: coverage.covered_range, missing_range: coverage.missing_range,
          actions: present || !supported ? [] : [ :retry ]
        )
      end

      def first_date(benchmark:, end_date:, importer:)
        activity_date = context&.first_trade_date || owner.trades.minimum(:traded_on)
        source_date = importer.available_from_for(benchmark:)
        [ activity_date, source_date ].compact.max || end_date
      end

      def historical_end_date
        @historical_end_date ||= if TradingCalendar.weekend?(today)
          TradingCalendar.previous_business_day(today + 1.day)
        else
          TradingCalendar.previous_business_day(today)
        end
      end

      def status_for(benchmark:, coverage:, supported:, end_date:)
        latest = coverage.latest_observed_on
        if benchmark.index? && latest && latest < end_date
          return latest < end_date - HistoricalObservationWindow::MAXIMUM_LOOKBACK_DAYS ? :stale : :delayed
        end
        return :healthy if coverage.complete?
        return :unsupported unless supported
        return :missing unless coverage.partial?
        return :partial unless benchmark.index?
        :partial
      end

      def description(benchmark, coverage, supported:, status:, end_date:)
        return "#{benchmark.name} has stored observations." if status == :healthy
        return "#{benchmark.name} has no configured recovery provider." unless supported

        if status == :stale
          "#{benchmark.name} (#{benchmark.identifier}) is stale; its latest observation is older than the " \
            "historical safety window before #{end_date.iso8601}. Missing observations: #{format_ranges(coverage.missing_ranges)}."
        elsif status == :delayed
          "#{benchmark.name} (#{benchmark.identifier}) is delayed; observations are not available through " \
            "#{end_date.iso8601}. Missing observations: #{format_ranges(coverage.missing_ranges)}."
        else
          "#{benchmark.name} (#{benchmark.identifier}) is missing observations for #{format_ranges(coverage.missing_ranges)}."
        end
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
