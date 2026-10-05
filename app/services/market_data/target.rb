module MarketData
  Target = Data.define(:kind, :record_id, :base_currency, :quote_currency, :provider) do
    KINDS = %i[
      current_price
      current_exchange_rate
      daily_closing_prices
      historical_exchange_rates
      benchmark_observations
      portfolio_performance
      instrument_performance
      corporate_action_imports
    ].freeze

    def initialize(kind:, record_id: nil, base_currency: nil, quote_currency: nil, provider: nil)
      kind = kind.to_sym
      raise ArgumentError, "unsupported market data target" unless KINDS.include?(kind)

      super(
        kind:,
        record_id:,
        base_currency: base_currency && CurrencyCode.normalize(base_currency),
        quote_currency: quote_currency && CurrencyCode.normalize(quote_currency),
        provider: provider&.to_s&.strip&.downcase
      )
    end

    def scope
      return "current_market_price:#{record_id}" if kind == :current_price

      [ "market_data_health", kind, record_id, base_currency, quote_currency, provider ].compact.join(":")
    end

    def publication_scope
      return "current_exchange_rate:#{[ base_currency, quote_currency ].sort.join(":")}" if kind == :current_exchange_rate
      return "historical_exchange_rate:#{[ base_currency, quote_currency ].sort.join(":")}" if kind == :historical_exchange_rates

      scope
    end
  end
end
