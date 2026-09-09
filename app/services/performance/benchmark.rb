module Performance
  class Benchmark
    # Return for one benchmark over a requested date range. The observations
    # retain their source dates so callers can explain which endpoints were used.
    Result = Data.define(:benchmark, :from, :to, :observations, :first_observation, :last_observation, :return_ratio, :status) do
      def available? = status == :available
      def missing? = status == :missing

      def cumulative_return_values
        return [] unless available?

        Performance::Benchmark.cumulative_return_values(benchmark:, observations:)
      end
    end

    def self.cumulative_return_values(benchmark:, observations:, baseline: false)
      return price_return_values(observations) if benchmark.price?

      values = [ BigDecimal("0") ]
      factor = BigDecimal("1")
      observations.drop(baseline ? 1 : 0).each do |observation|
        factor = (factor * (BigDecimal("1") + observation.value)).truncate(DailyRateReturn::ACCUMULATION_SCALE)
        values << factor - 1
      end
      baseline ? values : values.drop(1)
    end

    def self.price_return_values(observations)
      first = observations.first.value
      observations.map { |observation| observation.value / first - 1 }
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
      return missing_result(observations:) unless observations.length >= 2

      Result.new(
        benchmark:, from:, to:, observations:, first_observation: observations.first, last_observation: observations.last,
        return_ratio: calculate_return(observations), status: :available
      )
    end

    private

    attr_reader :benchmark, :from, :to

    def calculate_return(observations)
      if benchmark.rate?
        return DailyRateReturn.for(observations:, from: observations.first.observed_on,
          to: observations.last.observed_on + 1.day).return_ratio
      end

      observations.last.value / observations.first.value - 1
    end

    def missing_result(observations: [])
      Result.new(benchmark:, from:, to:, observations:, first_observation: nil, last_observation: nil, return_ratio: nil, status: :missing)
    end

    def validate_range!
      unless from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current
        raise ArgumentError, "benchmark period must use dates from the past in chronological order"
      end
    end
  end
end
