module CorporateActionImports
  Candidate = Data.define(
    :kind, :source_reference, :event_on, :amount_per_share, :ratio_numerator,
    :ratio_denominator, :currency, :provider_symbol, :provider_exchange,
    :raw_payload, :warnings
  )
end
