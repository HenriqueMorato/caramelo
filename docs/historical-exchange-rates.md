# Historical Exchange Rates

`HistoricalExchangeRate` stores durable dated currency-pair observations for
historical valuation and performance calculations. It is separate from
`ExchangeRateCache`, which is a replaceable cache for current quotes.

## Stored observation

Each record contains:

- `base_currency` and `quote_currency`: ISO currency codes describing the
  direction (`USD` to `BRL` means one USD expressed in BRL);
- `rate_date`: the market date represented by the observation;
- `rate`: a precise positive decimal rate;
- `provider`: the source adapter identifier;
- `observed_at`: when the provider observed the rate; and
- `fetched_at`: when LocalFolio received it.

The unique key is base currency, quote currency, rate date, and provider.
Imports are idempotent: a later observation for the same key updates the row,
so provider corrections do not create duplicates. Original trade currencies
and amounts are never rewritten.

## Lookup behavior

`HistoricalExchangeRate::Service#read` first searches for the requested pair
and date, then searches the reverse pair and returns its exact `BigDecimal`
inverse. A direct observation always wins when both directions exist. Same-
currency requests return a synthetic 1:1 result without storing a row. Missing
dates return an explicit missing result; the current-rate cache is never used
as a historical fallback.

Yahoo daily candle timestamps are interpreted as UTC dates, matching the daily
closing-price importer. This policy keeps persisted historical dates stable.

## Imports and scheduled capture

`HistoricalExchangeRate::Importer` accepts a single date or a backfill range,
rejects future/inverted ranges, reports missing weekdays, and validates every
provider observation before persistence. `CaptureHistoricalExchangeRatesJob`
runs daily through Solid Queue for each non-reporting currency used by the
owner's trades. Requests share the Yahoo provider lock and throttle with quote
and daily-price jobs, and one provider failure is reported without preventing
other currency pairs from running.

See [Market-data request throttling](market-data-request-throttling.md) for the
shared-provider coordination details.

Tests stub the transport and provider; they never call Yahoo Finance live.
