class DailyClosingPrice
  class Importer < MarketData::ObservationImporter
    include MarketData::ObservationPersistence

    def self.default
      new(provider: Providers::YahooFinance.new)
    end

    def initialize(provider:)
      @provider = provider
    end

    def call(instrument:, from:, to:, enqueue_performance_rebuild: true, fence: nil, generation: nil)
      @instrument = instrument
      super(from:, to:, enqueue_performance_rebuild:, fence:, generation:)
    end

    private

    attr_reader :provider, :instrument

    def validate_request!(from:, to:)
      raise ArgumentError, "from must be on or before to" if from > to
    end

    def fetch_observations
      provider.fetch(instrument:, from:, to:)
    end

    def result_for(counts:)
      Result.new(
        from:, to:, observations:, missing_dates: expected_dates - observations.map(&:trading_date),
        created_count: counts.fetch(:created), updated_count: counts.fetch(:updated)
      )
    end

    def persist_with_invalidation
      DailyClosingPrice.transaction do
        counts = persist
        @performance_users = mark_performance_observations_stale
        counts
      end
    end

    def validate_observations!
      observations.each do |observation|
        observation => { instrument: observed_instrument, currency:, provider: observed_provider }

        unless observed_instrument == instrument && currency == instrument.currency &&
            observed_provider == provider.identifier
          raise ArgumentError, "daily close observation does not match instrument or provider"
        end
      end
    end

    def persist
      observations.each_with_object(created: 0, updated: 0) do |observation, counts|
        observation => { instrument:, trading_date:, provider: }
        record = DailyClosingPrice.find_or_initialize_by(
          instrument:, trading_date:, provider:
        )
        outcome = persist_observation(record, observation)
        counts[outcome] += 1
      end
    end

    def expected_dates
      TradingCalendar.weekdays_between(from, to)
    end

    def mark_performance_observations_stale
      return [] if observations.empty?

      users = User.where(id: Trade.where(instrument:).select(:user_id)).to_a
      users.each do |user|
        Performance::ObservationInvalidator.mark!(user:, from: earliest_observation_date)
        Performance::ObservationInvalidator.mark_instrument!(
          user:, instrument:, from: earliest_observation_date
        )
      end
      users
    end

    def enqueue_performance_observations
      performance_users.each do |user|
        Performance::ObservationInvalidator.enqueue(user:, from: earliest_observation_date)
        Performance::ObservationInvalidator.enqueue_instrument(
          user:, instrument:, from: earliest_observation_date
        )
      end
    end

    def earliest_observation_date
      observations.map(&:trading_date).min
    end

    def persist_observation(record, observation)
      observation => { instrument:, trading_date:, provider:, close_price:, currency:, observed_at: }
      persist_record(record, attributes: { close_price:, currency:, observed_at: }) do
        DailyClosingPrice.find_by!(instrument:, trading_date:, provider:)
      end
    end
  end
end
