class DailyClosingPrice
  class Importer
    def self.default
      new(provider: Providers::YahooFinance.new)
    end

    def initialize(provider:)
      @provider = provider
    end

    def call(instrument:, from:, to:)
      raise ArgumentError, "from must be on or before to" if from > to

      observations = provider.fetch(instrument:, from:, to:)
      validate_observations!(observations, instrument:)
      counts = persist(observations)
      expected_dates = (from..to).reject { |date| date.saturday? || date.sunday? }

      Result.new(
        from:, to:, observations:, missing_dates: expected_dates - observations.map(&:trading_date),
        created_count: counts.fetch(:created), updated_count: counts.fetch(:updated)
      )
    end

    private

    attr_reader :provider

    def validate_observations!(observations, instrument:)
      observations.each do |observation|
        observation => { instrument: observed_instrument, currency:, provider: observed_provider }

        unless observed_instrument == instrument && currency == instrument.currency && observed_provider == provider.identifier
          raise ArgumentError, "daily close observation does not match instrument or provider"
        end
      end
    end

    def persist(observations)
      observations.each_with_object(created: 0, updated: 0) do |observation, counts|
        observation => { instrument:, trading_date:, provider: }
        record = DailyClosingPrice.find_or_initialize_by(
          instrument:, trading_date:, provider:
        )
        counts[record.new_record? ? :created : :updated] += 1
        persist_observation(record, observation)
      end
    end

    def persist_observation(record, observation)
      observation => { instrument:, trading_date:, provider:, close_price:, currency:, observed_at: }
      record.update!(
        close_price:, currency:, observed_at:
      )
    rescue ActiveRecord::RecordNotUnique
      DailyClosingPrice.find_by!(
        instrument:, trading_date:, provider:
      ).update!(
        close_price:, currency:, observed_at:
      )
    end
  end
end
