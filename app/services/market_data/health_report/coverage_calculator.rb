module MarketData
  class HealthReport
    # Describes real observations covering the dates needed by a valuation.
    # Missing ranges are compacted so the UI and recovery request stay small.
    Coverage = Data.define(
      :required_range, :covered_range, :missing_ranges, :latest_observed_on, :latest_fetched_at
    ) do
      def complete? = missing_ranges.empty?
      def partial? = covered_range.present? && missing_ranges.any?
      def missing? = covered_range.nil?

      def missing_range
        return if missing_ranges.empty?

        missing_ranges.first.begin..missing_ranges.last.end
      end
    end

    module CoverageCalculator
      module_function

      def for(required_dates:, observations:, carry_forward: false)
        dates = required_dates.sort.uniq
        return Coverage.new(required_range: nil, covered_range: nil, missing_ranges: [],
          latest_observed_on: nil, latest_fetched_at: nil) if dates.empty?

        observed_dates = observations.filter_map { |observation| observation_date(observation) }.to_set
        covered_dates = if carry_forward
          dates.select { |date| covered_by_prior_observation?(date, observed_dates) }
        else
          dates.select { |date| observed_dates.include?(date) }
        end
        missing_dates = dates - covered_dates
        Coverage.new(
          required_range: dates.min..dates.max,
          covered_range: covered_range(dates, covered_dates.to_set),
          missing_ranges: compact_ranges(missing_dates),
          latest_observed_on: observations.filter_map { |observation| observation_date(observation) }.max,
          latest_fetched_at: observations.filter_map { |observation| observation_fetched_at(observation) }.max
        )
      end

      def covered_by_prior_observation?(date, observed_dates)
        HistoricalObservationWindow.for(date).cover?(observed_dates.select { |observed| observed <= date }.max)
      end

      def compact_ranges(dates)
        dates.sort.slice_when { |left, right| right != left + 1.day }.map { |group| group.first..group.last }.to_a
      end

      def covered_range(required_dates, observed_dates)
        covered = required_dates.select { |date| observed_dates.include?(date) }
        covered.any? ? covered.min..covered.max : nil
      end

      def observation_date(observation)
        return observation.trading_date if observation.respond_to?(:trading_date)
        return observation.rate_date if observation.respond_to?(:rate_date)

        observation.observed_on
      end

      def observation_fetched_at(observation)
        return observation.fetched_at if observation.respond_to?(:fetched_at)
        return observation.observed_at if observation.respond_to?(:observed_at)

        nil
      end
    end
  end
end
