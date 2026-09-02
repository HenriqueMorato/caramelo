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

        observations = chart_observations(benchmark, result)
        cumulative_values = observations.equal?(result.observations) ? result.cumulative_return_values : cumulative_return_values(benchmark, observations)
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
      return observations unless benchmark.respond_to?(:persisted?) && benchmark.persisted? && observations.first

      # Anchor a range that starts during a closure to the prior real observation.
      anchor = benchmark.observations.where("observed_on < ?", series.observations.first.date).chronological.last
      anchor ? [ anchor, *observations ] : observations
    end

    def cumulative_return_values(benchmark, observations)
      if benchmark.kind == "rate"
        observations.reduce([ BigDecimal("0") ]) do |values, observation|
          values << ((BigDecimal("1") + values.last) * (BigDecimal("1") + observation.value) - 1)
        end.drop(1)
      else
        first = observations.first.value
        observations.map { |observation| observation.value / first - 1 }
      end
    end
  end
end
