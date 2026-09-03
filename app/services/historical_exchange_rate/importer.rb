class HistoricalExchangeRate
  class Importer
    def self.default
      new(provider: Providers::YahooFinance.new)
    end

    def initialize(provider:)
      @provider = provider
    end

    def call(base_currency:, quote_currency:, from:, to:, enqueue_performance_rebuild: true)
      validate_range!(from:, to:)
      @base_currency = normalize_currency(base_currency)
      @quote_currency = normalize_currency(quote_currency)
      raise ArgumentError, "currencies must differ" if @base_currency == @quote_currency
      @from = from
      @to = to
      @observations = provider.fetch(base_currency: @base_currency, quote_currency: @quote_currency, from:, to:)
      validate_observations!
      counts = persist_with_invalidation
      enqueue_performance_observations if enqueue_performance_rebuild

      Result.new(
        from:, to:, observations:, missing_dates: expected_dates - observations.map(&:rate_date),
        created_count: counts.fetch(:created), updated_count: counts.fetch(:updated)
      )
    end

    private

    attr_reader :provider, :base_currency, :quote_currency, :from, :to, :observations, :performance_users

    def validate_range!(from:, to:)
      unless from.is_a?(Date) && to.is_a?(Date)
        raise ArgumentError, "history range must use dates"
      end
      raise ArgumentError, "from must be on or before to" if from > to
      raise ArgumentError, "history range must be on or before today" if to > Date.current
    end

    def persist_with_invalidation
      HistoricalExchangeRate.transaction do
        counts = persist
        @performance_users = mark_performance_observations_stale
        counts
      end
    end

    def validate_observations!
      dates = Set.new
      observations.each do |observation|
        unless matching_pair_and_provider?(observation)
          raise ArgumentError, "historical rate observation does not match pair or provider"
        end
        unless within_requested_range?(observation.rate_date)
          raise ArgumentError, "historical rate observation is outside requested range"
        end

        unless dates.add?(observation.rate_date)
          raise ArgumentError, "historical rate observations contain duplicate dates"
        end
      end
    end

    def matching_pair_and_provider?(observation)
      observation.base_currency == base_currency && observation.quote_currency == quote_currency &&
        observation.provider == provider.identifier
    end

    def within_requested_range?(date)
      date.is_a?(Date) && (from..to).cover?(date) && date <= Date.current
    end

    def persist
      observations.each_with_object(created: 0, updated: 0) do |observation, counts|
        record = HistoricalExchangeRate.find_or_initialize_by(
          base_currency: observation.base_currency, quote_currency: observation.quote_currency,
          rate_date: observation.rate_date, provider: observation.provider
        )
        outcome = persist_observation(record, observation)
        counts[outcome] += 1
      end
    end

    def persist_observation(record, observation)
      created = record.new_record?
      record.update!(rate: observation.rate, observed_at: observation.observed_at, fetched_at: observation.fetched_at)
      created ? :created : :updated
    rescue ActiveRecord::RecordNotUnique
      HistoricalExchangeRate.find_by!(
        base_currency: observation.base_currency, quote_currency: observation.quote_currency,
        rate_date: observation.rate_date, provider: observation.provider
      ).update!(rate: observation.rate, observed_at: observation.observed_at, fetched_at: observation.fetched_at)
      :updated
    end

    def expected_dates
      TradingCalendar.weekdays_between(from, to)
    end

    def mark_performance_observations_stale
      return [] if observations.empty?

      users = affected_users.to_a
      users.each do |user|
        Performance::ObservationInvalidator.mark!(user:, from: earliest_observation_date)
      end
      users
    end

    def enqueue_performance_observations
      performance_users.each do |user|
        Performance::ObservationInvalidator.enqueue(user:, from: earliest_observation_date)
      end
    end

    def earliest_observation_date
      observations.map(&:rate_date).min
    end

    def affected_users
      # Valuation can resolve either the direct rate or its inverse.
      User.where(id: Trade.where(currency: [ base_currency, quote_currency ]).select(:user_id))
    end

    def normalize_currency(currency)
      CurrencyCode.normalize(currency)
    end
  end
end
