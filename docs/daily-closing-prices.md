# Daily Closing Prices

`DailyClosingPrice` stores durable end-of-day observations for later portfolio
valuation and performance calculations. It is deliberately separate from
`CurrentMarketPrice`, which remains replaceable cache data for the live UI.

## Stored observation

Each record belongs to an instrument and contains:

- `trading_date`: the exchange observation date;
- `close_price`: a precise decimal price (up to eight fractional places), not
  an integer currency subunit, so fractional ETF and crypto prices are not
  rounded away;
- `currency`: the instrument's ISO currency;
- `provider`: the source adapter identifier; and
- `observed_at`: the provider timestamp.

Importer results also expose the requested `from` and `to` dates, returned
`observations`, `missing_dates`, and separate `created_count` and
`updated_count` values.

The unique key is instrument, trading date, and provider. Re-importing a date
updates the existing row, allowing provider corrections without duplicates.
Historical trade prices are never changed.

## Imports and missing days

`DailyClosingPrice::Importer` accepts an instrument and date range. Providers
return only observations that exist; the importer reports weekdays with no
observation as `missing_dates`. Weekends and exchange holidays are not created
as fake zero-price rows. Callers can apply an exchange calendar when deciding
whether an absent weekday is expected.

Yahoo Finance history is parsed through the isolated history client and only
daily (`1d`) observations are persisted. Current-cache entries are never
copied into this table.

`CaptureDailyClosingPricesJob` runs from Solid Queue's daily schedule for every
instrument with an owner trade and captures the prior business day. A provider
failure is reported per instrument so one failure does not prevent the
remaining instruments from being attempted. Performance may use a persisted
close from its explicit seven-day safety window for weekends and short holidays;
it never treats an arbitrary old close as current.

Trade changes use the durable background workflow described in
[Historical data backfills](historical-data-backfills.md) to import any older
dates needed for performance.
