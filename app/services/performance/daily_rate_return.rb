module Performance
  class DailyRateReturn
    # B3 accumulates DI factors with 16 decimal places at each step, then
    # rounds the final factor to 8 places. Values here are decimal ratios.
    Result = Data.define(:from, :to, :observations, :factor, :return_ratio) do
      def available? = observations.any?
    end

    ACCUMULATION_SCALE = 16
    FINAL_SCALE = 8

    def self.for(observations:, from:, to:)
      new(observations:, from:, to:).calculate
    end

    def initialize(observations:, from:, to:)
      @observations = observations
      @from = from
      @to = to
    end

    def calculate
      validate_range!
      selected = observations.select { |observation| (from...to).cover?(observation.observed_on) }
      factor = selected.reduce(BigDecimal("1")) do |total, observation|
        (total * (BigDecimal("1") + observation.value)).truncate(ACCUMULATION_SCALE)
      end
      factor = factor.round(FINAL_SCALE)

      Result.new(from:, to:, observations: selected, factor:, return_ratio: factor - 1)
    end

    private

    attr_reader :observations, :from, :to

    def validate_range!
      return if from.is_a?(Date) && to.is_a?(Date) && from < to

      raise ArgumentError, "daily rate interval must use dates in chronological order"
    end
  end
end
