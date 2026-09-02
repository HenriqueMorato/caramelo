class MarketBenchmark
  class Importer
    Result = Data.define(:benchmark, :from, :to, :observations, :missing_dates, :created_count, :updated_count)

    def self.default
      new(provider: Providers::YahooFinance.new)
    end

    def initialize(provider:)
      @provider = provider
    end

    def supports?(benchmark:)
      provider.supports?(benchmark:)
    end

    def identifier
      provider.identifier
    end

    def call(benchmark:, from:, to:)
      raise ArgumentError, "from must be on or before to" if from > to

      @benchmark = benchmark
      @from = from
      @to = to
      @observations = provider.fetch(benchmark:, from:, to:)
      validate_observations!
      counts = persist

      Result.new(
        benchmark:, from:, to:, observations:, missing_dates: expected_dates - observations.map(&:observed_on),
        created_count: counts.fetch(:created), updated_count: counts.fetch(:updated)
      )
    end

    private

    attr_reader :provider, :benchmark, :from, :to, :observations

    def validate_observations!
      observations.each do |observation|
        unless observation.market_benchmark == benchmark && observation.currency == benchmark.currency &&
            observation.provider == provider.identifier
          raise ArgumentError, "benchmark observation does not match benchmark or provider"
        end
      end
    end

    def persist
      observations.each_with_object(created: 0, updated: 0) do |observation, counts|
        record = MarketBenchmarkObservation.find_or_initialize_by(
          market_benchmark: benchmark, observed_on: observation.observed_on, provider: observation.provider
        )
        created = record.new_record?
        record.update!(value: observation.value, currency: observation.currency, observed_at: observation.observed_at)
        counts[created ? :created : :updated] += 1
      end
    end

    def expected_dates
      (from..to).reject { |date| date.saturday? || date.sunday? }
    end
  end
end
