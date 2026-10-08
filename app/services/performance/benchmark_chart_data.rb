module Performance
  class BenchmarkChartData
    def self.for(series:, benchmark_results:)
      new(series:, benchmark_results:).to_a
    end

    def initialize(series:, benchmark_results:)
      @series = series
      @benchmark_results = benchmark_results
    end

    def to_a
      benchmark_results.filter_map do |benchmark, result|
        next unless result.available? || result.missing?

        observations = result.respond_to?(:chart_observations) ? result.chart_observations : chart_observations(benchmark, result)
        next if result.missing? && observations.length < 2

        cumulative_values = if result.respond_to?(:chart_cumulative_return_values)
          result.chart_cumulative_return_values
        elsif result.available? && observations.equal?(result.observations)
          result.cumulative_return_values
        else
          Performance::Benchmark.cumulative_return_values(
            benchmark:, observations:, baseline: observations.length > result.observations.length
          )
        end
        values_by_date = observations.zip(cumulative_values).to_h do |observation, value|
          [ observation.observed_on, value.to_f * 100 ]
        end
        values = values_by_date.sort
        index = -1
        last_value = nil
        {
          identifier: benchmark.identifier,
          label: benchmark.name,
          values: series.observations.map do |observation|
            index += 1 while values[index + 1]&.first && values[index + 1].first <= observation.date
            last_value = index >= 0 ? values[index].last : last_value
          end
        }
      end
    end

    private

    attr_reader :series, :benchmark_results

    def chart_observations(benchmark, result)
      observations = result.observations
      first_date = series.observations.first&.date
      return observations unless benchmark.persisted? && observations.first && first_date
      return observations unless observations.first.observed_on > first_date

      # Anchor a range that starts during a closure to the prior real observation.
      anchor = benchmark.observations.where(observed_on: ...first_date).chronological.last
      return observations unless valid_anchor?(anchor, first_date)

      [ anchor, *observations ]
    end

    def valid_anchor?(anchor, first_date)
      anchor && MarketData::HistoricalObservationWindow.for(first_date).cover?(anchor.observed_on)
    end
  end
end
