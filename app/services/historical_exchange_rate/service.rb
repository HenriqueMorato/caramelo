class HistoricalExchangeRate
  class Service
    def initialize(provider: nil)
      @provider = provider
    end

    def read(base_currency:, quote_currency:, rate_date:)
      base_currency = normalize_currency(base_currency)
      quote_currency = normalize_currency(quote_currency)
      validate_rate_date!(rate_date)
      return same_currency_lookup(base_currency:, quote_currency:, rate_date:) if base_currency == quote_currency

      direct = find(base_currency:, quote_currency:, rate_date:)
      return available_lookup(direct, inverted: false) if direct

      inverse = find(base_currency: quote_currency, quote_currency: base_currency, rate_date:)
      return available_lookup(inverse, inverted: true) if inverse

      HistoricalExchangeRate::Lookup.new(exchange_rate: nil, status: :missing, inverted: false)
    end

    private

    attr_reader :provider

    def find(base_currency:, quote_currency:, rate_date:)
      HistoricalExchangeRate.find_by(base_currency:, quote_currency:, rate_date:, provider: provider_identifier)
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
      provider&.identifier || MarketData::YahooFinance::FX_PROVIDER_IDENTIFIER
    end

    def normalize_currency(currency)
      iso_code = currency.to_s.strip.upcase
      raise ArgumentError, "currency is invalid" unless Money::Currency.find(iso_code)

      iso_code
    end

    def validate_rate_date!(rate_date)
      raise ArgumentError, "rate date must be on or before today" unless rate_date.is_a?(Date) && rate_date <= Date.current
    end
  end
end
