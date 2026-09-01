module Performance
  class Benchmark
    # Return for one benchmark over a requested date range. The observations
    # retain their source dates so callers can explain which endpoints were used.
    Result = Data.define(:benchmark, :from, :to, :first_observation, :last_observation, :return_ratio, :status) do
      def available? = status == :available
      def missing? = status == :missing
    end

    def self.for(benchmark:, from:, to:)
      new(benchmark:, from:, to:).calculate
    end

    def initialize(benchmark:, from:, to:)
      @benchmark = benchmark
      @from = from
      @to = to
    end

    def calculate
      validate_range!
      observations = benchmark.observations.where(observed_on: from..to).chronological.to_a
      return missing_result unless observations.length >= 2

      Result.new(
        benchmark:, from:, to:, first_observation: observations.first, last_observation: observations.last,
        return_ratio: calculate_return(observations), status: :available
      )
    end

    private

    attr_reader :benchmark, :from, :to

    def calculate_return(observations)
      if benchmark.kind == "rate"
        growth = observations.reduce(BigDecimal("1")) { |factor, observation| factor * (BigDecimal("1") + observation.value) }
        return growth - 1
      end

      observations.last.value / observations.first.value - 1
    end

    def missing_result
      Result.new(benchmark:, from:, to:, first_observation: nil, last_observation: nil, return_ratio: nil, status: :missing)
    end

    def validate_range!
      unless from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current
        raise ArgumentError, "benchmark period must use dates from the past in chronological order"
      end
    end
  end
end
