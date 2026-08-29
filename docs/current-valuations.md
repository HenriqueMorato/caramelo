# Current Valuation

Positions keep their native instrument currency for trades, fees, cost basis,
and cached market prices. The Positions page additionally shows market value in
the configured reporting currency (`BRL` by default).

## Conversion flow

1. `CurrentMarketPrice#valuation_amount_for` multiplies the precise quote by
   the precise position quantity without rounding.
2. `Valuation::Current` uses the quote currency and reporting currency to
   request an exchange-rate lookup.
3. Same-currency values skip the provider and are wrapped directly in Money.
4. Foreign values multiply by the precise FX rate and round once when creating
   the reporting-currency Money value.

Trade prices, fees, cost basis, and cached quotes are never mutated or
converted in storage.

## Yahoo Finance FX provider

`ExchangeRate::Providers::YahooFinance` requests Yahoo currency-pair symbols
such as `USDBRL=X` through the isolated Yahoo transport. The provider returns
the quote currency per unit of the base currency, its observed market time, and
the fetch time. It is an unofficial, credential-free source intended for this
personal, self-hosted application; the existing Yahoo request throttle applies,
and a failed FX refresh leaves any previous stale rate available.

See [Market-data request throttling](market-data-request-throttling.md) for the
provider-wide coordination behavior.

`ExchangeRateCache` keeps the last valid rate indefinitely and marks it fresh
for 30 minutes. A stale rate remains usable for display and is marked stale;
missing or invalid rates produce an unavailable valuation rather than silently
assuming a 1:1 conversion. A future provider can implement the same adapter
interface without changing valuation or view code.
