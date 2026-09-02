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

        values_by_date = result.observations.zip(result.cumulative_return_values).to_h do |observation, value|
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
  end
end
