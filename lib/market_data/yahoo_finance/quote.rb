module MarketData
  module YahooFinance
    # symbol: Yahoo's listing identifier.
    # unit_price: price normalized to the major unit of currency.
    # currency: normalized ISO currency used by LocalFolio.
    # quoted_at: market timestamp reported by Yahoo.
    # provider_exchange: raw Yahoo venue metadata used to validate the MIC.
    # instrument_type: raw Yahoo classification, such as EQUITY or ETF.
    # provider_currency: raw Yahoo denomination, including GBp or GBX.
    Quote = Data.define(
      :symbol,
      :unit_price,
      :currency,
      :quoted_at,
      :provider_exchange,
      :instrument_type,
      :provider_currency
    )
  end
end
