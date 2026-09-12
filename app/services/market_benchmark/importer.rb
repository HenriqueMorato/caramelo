class MarketBenchmark
  class Importer
    Result = Data.define(:benchmark, :from, :to, :observations, :missing_dates, :created_count, :updated_count)

    def self.default
      new(providers: [ Providers::YahooFinance.new, Providers::Bcb.new ])
    end

    def initialize(provider: nil, providers: nil)
      @providers = providers || [ provider ]
      @provider = provider || providers&.first
    end

    def supports?(benchmark:)
      provider_for(benchmark:).present?
    end

    def identifier(benchmark: nil)
      benchmark ? identifier_for(benchmark:) : providers.first&.identifier
    end

    def identifier_for(benchmark:)
      provider_for(benchmark:)&.identifier
    end

    def expected_dates_for(benchmark:, from:, to:)
      selected_provider = provider_for(benchmark:)
      return selected_provider.expected_dates(from:, to:) if selected_provider&.respond_to?(:expected_dates)

      TradingCalendar.weekdays_between(from, to)
    end

    def call(benchmark:, from:, to:, fence: nil)
      raise ArgumentError, "from must be on or before to" if from > to

      generation = fence&.capture
      @benchmark = benchmark
      @from = from
      @to = to
      @provider = provider_for(benchmark:)
      raise ArgumentError, "benchmark provider is unsupported" unless provider
      @observations = provider.fetch(benchmark:, from:, to:)
      validate_observations!
      counts = if fence
        result = nil
        return Result.new(benchmark:, from:, to:, observations:, missing_dates: expected_dates - observations.map(&:observed_on),
          created_count: 0, updated_count: 0) if fence.publish(generation) { result = persist } == :superseded

        result
      else
        persist
      end

      Result.new(
        benchmark:, from:, to:, observations:, missing_dates: expected_dates - observations.map(&:observed_on),
        created_count: counts.fetch(:created), updated_count: counts.fetch(:updated)
      )
    end

    private

    attr_reader :provider, :benchmark, :from, :to, :observations, :providers

    def provider_for(benchmark:)
      return provider if providers.one?

      providers.find { |candidate| candidate.supports?(benchmark:) }
    end

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
      expected_dates_for(benchmark:, from:, to:)
    end
  end
end
