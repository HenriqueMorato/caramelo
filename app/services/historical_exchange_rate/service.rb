class HistoricalExchangeRate
  class Service
    def initialize(provider: nil)
      @provider = provider
      @lookups = {}
    end

    def read(base_currency:, quote_currency:, rate_date:)
      base_currency = normalize_currency(base_currency)
      quote_currency = normalize_currency(quote_currency)
      validate_rate_date!(rate_date)
      key = lookup_key(base_currency:, quote_currency:, rate_date:)
      return @lookups[key] if @lookups.key?(key)
      return @lookups[key] = same_currency_lookup(base_currency:, quote_currency:, rate_date:) if base_currency == quote_currency

      direct = find(base_currency:, quote_currency:, rate_date:)
      return @lookups[key] = available_lookup(direct, inverted: false) if direct

      inverse = find(base_currency: quote_currency, quote_currency: base_currency, rate_date:)
      return @lookups[key] = available_lookup(inverse, inverted: true) if inverse

      missing_lookup
    end

    # Preloads all requested dates with two range queries, retaining the same
    # seven-day prior-observation rule as individual reads. Performance pages
    # share one service across benchmarks so a foreign currency pair is loaded
    # only once per request.
    def preload(base_currency:, quote_currency:, rate_dates:)
      base_currency = normalize_currency(base_currency)
      quote_currency = normalize_currency(quote_currency)
      dates = rate_dates.uniq
      dates.each { |date| validate_rate_date!(date) }
      return if dates.empty?

      if base_currency == quote_currency
        dates.each do |date|
          key = lookup_key(base_currency:, quote_currency:, rate_date: date)
          @lookups[key] ||= same_currency_lookup(base_currency:, quote_currency:, rate_date: date)
        end
        return
      end

      window = (dates.min - MarketData::HistoricalObservationWindow::MAXIMUM_LOOKBACK_DAYS)..dates.max
      direct = HistoricalExchangeRate.where(
        base_currency:, quote_currency:, provider: provider_identifier, rate_date: window
      ).order(:rate_date).index_by(&:rate_date)
      inverse = HistoricalExchangeRate.where(
        base_currency: quote_currency, quote_currency: base_currency, provider: provider_identifier, rate_date: window
      ).order(:rate_date).index_by(&:rate_date)

      dates.each do |date|
        key = lookup_key(base_currency:, quote_currency:, rate_date: date)
        next if @lookups.key?(key)

        # A preload is a request-scoped snapshot, so cache misses too; this
        # keeps an unavailable range from falling back to one query per date.
        direct_record = latest_record(direct, date)
        if direct_record
          @lookups[key] = available_lookup(direct_record, inverted: false)
        else
          inverse_record = latest_record(inverse, date)
          @lookups[key] = if inverse_record
            available_lookup(inverse_record, inverted: true)
          else
            missing_lookup
          end
        end
      end
    end

    private

    attr_reader :provider

    def find(base_currency:, quote_currency:, rate_date:)
      HistoricalExchangeRate.where(base_currency:, quote_currency:, provider: provider_identifier)
        .where(rate_date: MarketData::HistoricalObservationWindow.for(rate_date))
        .order(rate_date: :desc)
        .first
    end

    def latest_record(records_by_date, date)
      (date - MarketData::HistoricalObservationWindow::MAXIMUM_LOOKBACK_DAYS..date).reverse_each do |candidate|
        record = records_by_date[candidate]
        return record if record
      end
      nil
    end

    def missing_lookup
      HistoricalExchangeRate::Lookup.new(exchange_rate: nil, status: :missing, inverted: false)
    end

    def lookup_key(base_currency:, quote_currency:, rate_date:)
      [ base_currency, quote_currency, rate_date ]
    end

    def available_lookup(record, inverted:)
      rate = inverted ? BigDecimal(1.to_s) / record.rate : record.rate
      resolved = HistoricalExchangeRate::ResolvedRate.new(
        base_currency: inverted ? record.quote_currency : record.base_currency,
        quote_currency: inverted ? record.base_currency : record.quote_currency,
        rate_date: record.rate_date, rate:, provider: record.provider,
        observed_at: record.observed_at, fetched_at: record.fetched_at
      )
      HistoricalExchangeRate::Lookup.new(exchange_rate: resolved, status: :available, inverted:)
    end

    def same_currency_lookup(base_currency:, quote_currency:, rate_date:)
      rate = HistoricalExchangeRate::ResolvedRate.new(
        base_currency:, quote_currency:, rate_date:, rate: BigDecimal("1"),
        provider: provider_identifier, observed_at: nil, fetched_at: nil
      )
      HistoricalExchangeRate::Lookup.new(exchange_rate: rate, status: :same_currency, inverted: false)
    end

    def provider_identifier
      provider&.identifier || MarketData::YahooFinance::FX_CONFIGURATION.identifier
    end

    def normalize_currency(currency)
      CurrencyCode.normalize(currency)
    end

    def validate_rate_date!(rate_date)
      raise ArgumentError, "rate date must be on or before today" unless rate_date.is_a?(Date) && rate_date <= Date.current
    end
  end
end
