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
        next unless result.available?

        chart_for(benchmark, result)
      end
    end

    private

    attr_reader :series, :benchmark_results

    def chart_for(benchmark, result)
      observations = observations_for(benchmark, result)
      values = values_for(benchmark, result, observations)

      {
        identifier: benchmark.identifier,
        label: benchmark.name,
        values: chart_values(values)
      }
    end

    def observations_for(benchmark, result)
      return result.chart_observations if result.respond_to?(:chart_observations)

      chart_observations(benchmark, result)
    end

    def values_for(benchmark, result, observations)
      cumulative_values = cumulative_values_for(benchmark, result, observations)

      observations.zip(cumulative_values).to_h do |observation, value|
        [ observation.observed_on, value.to_f * 100 ]
      end.sort
    end

    def cumulative_values_for(benchmark, result, observations)
      return result.chart_cumulative_return_values if result.respond_to?(:chart_cumulative_return_values)
      return result.cumulative_return_values if observations.equal?(result.observations)

      Performance::Benchmark.cumulative_return_values(
        benchmark:, observations:, baseline: observations.length > result.observations.length
      )
    end

    def chart_values(values)
      index = -1
      series.observations.map do |observation|
        index = advance_index(values, index, observation.date)
        value_for(values, index, observation.date)
      end
    end

    def advance_index(values, index, date)
      index += 1 while values[index + 1]&.first && values[index + 1].first <= date
      index
    end

    def value_for(values, index, date)
      return unless index >= 0
      return unless MarketData::HistoricalObservationWindow.for(date).cover?(values[index].first)

      values[index].last
    end

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
