class CurrentMarketPrice
  class InvalidValue < ArgumentError; end
  class InvalidPayload < ArgumentError; end

  attr_reader :unit_price, :currency, :provider, :quoted_at, :fetched_at

  def self.from_cache_payload(payload)
    raise InvalidPayload, "payload must be a hash" unless payload.is_a?(Hash)

    new(
      unit_price: payload.fetch("unit_price"),
      currency: payload.fetch("currency"),
      provider: payload.fetch("provider"),
      quoted_at: Time.iso8601(payload.fetch("quoted_at")),
      fetched_at: Time.iso8601(payload.fetch("fetched_at"))
    )
  rescue InvalidPayload
    raise
  rescue KeyError, TypeError, ArgumentError => error
    raise InvalidPayload, error.message
  end

  def self.normalize_provider(provider)
    normalized_provider = provider.to_s.strip.downcase
    return normalized_provider if normalized_provider.match?(/\A[a-z0-9][a-z0-9_-]{0,63}\z/)

    raise InvalidValue, "provider is invalid"
  end

  def initialize(unit_price:, currency:, provider:, quoted_at:, fetched_at:)
    @unit_price = decimal(unit_price, name: "unit price", positive: true)
    @currency = normalize_currency(currency)
    @provider = self.class.normalize_provider(provider)
    @quoted_at = normalize_time(quoted_at, name: "quoted at")
    @fetched_at = normalize_time(fetched_at, name: "fetched at")
    freeze
  end

  def stale?(at:, fresh_for:)
    fetched_at <= normalize_time(at, name: "current time") - fresh_for
  end

  def valuation_for(quantity)
    normalized_quantity = decimal(quantity, name: "quantity")
    raise InvalidValue, "quantity must be greater than or equal to 0" if normalized_quantity.negative?

    # Keep subunit precision until Money rounds the aggregate position value.
    Money.from_amount(unit_price * normalized_quantity, currency)
  end

  def to_cache_payload
    # A decimal string round-trips without introducing binary float error.
    {
      "unit_price" => unit_price.to_s("F"),
      "currency" => currency,
      "provider" => provider,
      "quoted_at" => quoted_at.iso8601(6),
      "fetched_at" => fetched_at.iso8601(6)
    }
  end

  private

  def decimal(value, name:, positive: false)
    raise InvalidValue, "#{name} must not be a float" if value.is_a?(Float)

    decimal = BigDecimal(value.to_s)
    raise InvalidValue, "#{name} must be finite" unless decimal.finite?
    raise InvalidValue, "#{name} must be greater than 0" if positive && !decimal.positive?

    decimal
  rescue InvalidValue
    raise
  rescue ArgumentError
    raise InvalidValue, "#{name} is invalid"
  end

  def normalize_currency(currency)
    iso_code = currency.to_s.strip.upcase
    money_currency = Money::Currency.find(iso_code) if iso_code.match?(/\A[A-Z]{3}\z/)
    return iso_code if money_currency&.iso_numeric&.match?(/\A\d{3}\z/)

    raise InvalidValue, "currency is invalid"
  end

  def normalize_time(value, name:)
    value.to_time.utc
  rescue NoMethodError, ArgumentError
    raise InvalidValue, "#{name} is invalid"
  end
end
