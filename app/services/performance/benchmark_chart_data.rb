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
        {
          identifier: benchmark.identifier,
          label: benchmark.name,
          values: series.observations.map { |observation| values_by_date[observation.date] }
        }
      end
    end

    private

    attr_reader :series, :benchmark_results
  end
end
