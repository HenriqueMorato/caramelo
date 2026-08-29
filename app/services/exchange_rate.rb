module ExchangeRate
  Rate = Data.define(:base_currency, :quote_currency, :rate, :observed_on, :fetched_at, :provider) do
    def stale?(fresh_for:, at: Time.current)
      fetched_at <= at - fresh_for
    end

    def to_cache_payload
      {
        "base_currency" => base_currency,
        "quote_currency" => quote_currency,
        "rate" => rate.to_s("F"),
        "observed_on" => observed_on.iso8601,
        "fetched_at" => fetched_at.iso8601(6),
        "provider" => provider
      }
    end
  end

  class InvalidValue < ArgumentError; end
  class InvalidPayload < ArgumentError; end
end
