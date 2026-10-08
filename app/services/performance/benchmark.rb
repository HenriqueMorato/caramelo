module Performance
  class Benchmark
    # Benchmark observations may be compared in the portfolio's reporting
    # currency. Source observations remain untouched; converted observations
    # are kept on the result for return and chart calculations.
    Result = Data.define(
      :benchmark, :from, :to, :observations, :first_observation, :last_observation,
      :return_ratio, :status, :calculation_observations, :chart_observations
    ) do
      def available? = status == :available
      def missing? = status == :missing

      def cumulative_return_values
        return [] unless available?

        Performance::Benchmark.cumulative_return_values(benchmark:, observations: calculation_observations)
      end

      def chart_cumulative_return_values
        return [] if chart_observations.length < 2

        Performance::Benchmark.cumulative_return_values(
          benchmark:, observations: chart_observations,
          baseline: chart_observations.length > calculation_observations.length
        )
      end
    end

    class << Result
      alias_method :build, :new

      def new(benchmark:, from:, to:, observations:, first_observation:, last_observation:,
        return_ratio:, status:, calculation_observations: observations, chart_observations: nil)
        build(benchmark:, from:, to:, observations:, first_observation:, last_observation:,
          return_ratio:, status:, calculation_observations:, chart_observations: chart_observations || calculation_observations)
      end
    end

    def self.cumulative_return_values(benchmark:, observations:, baseline: false)
      return price_return_values(observations) if benchmark.index?

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

    def self.for(benchmark:, from:, to:, reporting_currency: benchmark.currency,
      exchange_rate_service: HistoricalExchangeRate::Service.new)
      new(benchmark:, from:, to:, reporting_currency:, exchange_rate_service:).calculate
    end

    def initialize(benchmark:, from:, to:, reporting_currency:, exchange_rate_service:)
      @benchmark = benchmark
      @from = from
      @to = to
      @reporting_currency = CurrencyCode.normalize(reporting_currency)
      @exchange_rate_service = exchange_rate_service
    end

    def calculate
      validate_range!
      observations = benchmark.observations.where(observed_on: from..to).chronological.to_a
      return missing_result(observations:) unless observations.length >= 2

      calculation_observations = convert_observations(observations)
      return missing_result(observations:, calculation_observations:) unless calculation_observations.length == observations.length

      Result.new(
        benchmark:, from:, to:, observations:, first_observation: observations.first, last_observation: observations.last,
        return_ratio: calculate_return(calculation_observations), status: :available,
        calculation_observations:, chart_observations: chart_observations(observations, calculation_observations)
      )
    end

    private

    attr_reader :benchmark, :from, :to, :reporting_currency, :exchange_rate_service

    def calculate_return(observations)
      if benchmark.rate?
        return DailyRateReturn.for(observations:, from: observations.first.observed_on,
          to: observations.last.observed_on + 1.day).return_ratio
      end

      observations.last.value / observations.first.value - 1
    end

    def missing_result(observations: [], calculation_observations: observations)
      chart_points = if calculation_observations.length < observations.length
        []
      elsif observations.empty?
        calculation_observations
      else
        chart_observations(observations, calculation_observations)
      end
      Result.new(benchmark:, from:, to:, observations:, first_observation: nil, last_observation: nil,
        return_ratio: nil, status: :missing, calculation_observations:,
        chart_observations: chart_points)
    end

    def convert_observations(observations)
      return observations if benchmark.rate? || reporting_currency == benchmark.currency

      preload_exchange_rates(observations)
      observations.filter_map { |observation| convert_observation(observation) }
    end

    def preload_exchange_rates(observations)
      return unless exchange_rate_service.respond_to?(:preload)

      exchange_rate_service.preload(
        base_currency: benchmark.currency, quote_currency: reporting_currency,
        rate_dates: observations.map(&:observed_on)
      )
    end

    def convert_observation(observation)
      lookup = exchange_rate_service.read(
        base_currency: benchmark.currency, quote_currency: reporting_currency, rate_date: observation.observed_on
      )
      return unless lookup.available?

      MarketBenchmarkObservation::Observation.new(
        market_benchmark: benchmark, observed_on: observation.observed_on,
        value: observation.value.to_d * lookup.exchange_rate.rate.to_d,
        currency: reporting_currency, provider: observation.provider, observed_at: observation.observed_at
      )
    end

    def chart_observations(observations, calculation_observations)
      return calculation_observations unless observations.first.observed_on > from

      anchor = benchmark.observations.where(observed_on: ...from).chronological.last
      return calculation_observations unless anchor && MarketData::HistoricalObservationWindow.for(from).cover?(anchor.observed_on)

      converted_anchor = convert_observations([ anchor ]).first
      return calculation_observations unless converted_anchor

      [ converted_anchor, *calculation_observations ]
    end

    def validate_range!
      unless from.is_a?(Date) && to.is_a?(Date) && from <= to && to <= Date.current
        raise ArgumentError, "benchmark period must use dates from the past in chronological order"
      end
    end
  end
end
