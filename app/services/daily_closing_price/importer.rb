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

      @instrument = instrument
      @from = from
      @to = to
      @observations = provider.fetch(instrument:, from:, to:)
      validate_observations!
      counts = persist

      Result.new(
        from:, to:, observations:, missing_dates: expected_dates - observations.map(&:trading_date),
        created_count: counts.fetch(:created), updated_count: counts.fetch(:updated)
      )
    end

    private

    attr_reader :provider, :instrument, :from, :to, :observations

    def validate_observations!
      observations.each do |observation|
        observation => { instrument: observed_instrument, currency:, provider: observed_provider }

        unless observed_instrument == instrument && currency == instrument.currency && observed_provider == provider.identifier
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

    def persist_observation(record, observation)
      observation => { instrument:, trading_date:, provider:, close_price:, currency:, observed_at: }
      created = record.new_record?
      record.update!(
        close_price:, currency:, observed_at:
      )
      created ? :created : :updated
    rescue ActiveRecord::RecordNotUnique
      DailyClosingPrice.find_by!(
        instrument:, trading_date:, provider:
      ).update!(
        close_price:, currency:, observed_at:
      )
      :updated
    end
  end
end
