class HistoricalExchangeRate
  class Importer
    def self.default
      new(provider: Providers::YahooFinance.new)
    end

    def initialize(provider:)
      @provider = provider
    end

    def call(base_currency:, quote_currency:, from:, to:)
      unless from.is_a?(Date) && to.is_a?(Date)
        raise ArgumentError, "history range must use dates"
      end
      raise ArgumentError, "from must be on or before to" if from > to
      raise ArgumentError, "history range must be on or before today" if to > Date.current

      @base_currency = normalize_currency(base_currency)
      @quote_currency = normalize_currency(quote_currency)
      raise ArgumentError, "currencies must differ" if @base_currency == @quote_currency
      @from = from
      @to = to
      @observations = provider.fetch(base_currency: @base_currency, quote_currency: @quote_currency, from:, to:)
      validate_observations!
      counts = persist

      Result.new(
        from:, to:, observations:, missing_dates: expected_dates - observations.map(&:rate_date),
        created_count: counts.fetch(:created), updated_count: counts.fetch(:updated)
      )
    end

    private

    attr_reader :provider, :base_currency, :quote_currency, :from, :to, :observations

    def validate_observations!
      dates = Set.new
      observations.each do |observation|
        unless observation.base_currency == base_currency && observation.quote_currency == quote_currency && observation.provider == provider.identifier
          raise ArgumentError, "historical rate observation does not match pair or provider"
        end
        unless observation.rate_date.is_a?(Date) && (from..to).cover?(observation.rate_date) && observation.rate_date <= Date.current
          raise ArgumentError, "historical rate observation is outside requested range"
        end

        raise ArgumentError, "historical rate observations contain duplicate dates" unless dates.add?(observation.rate_date)
      end
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
      (from..to).reject { |date| date.saturday? || date.sunday? }
    end

    def normalize_currency(currency)
      iso_code = currency.to_s.strip.upcase
      raise ArgumentError, "currency is invalid" unless Money::Currency.find(iso_code)

      iso_code
    end
  end
end
