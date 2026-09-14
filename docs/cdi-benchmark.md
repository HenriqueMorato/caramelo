# CDI benchmark

caramelo reads the CDI daily rate from Banco Central do Brasil’s SGS series
12. The service receives the published percentage as a decimal string and
normalizes it once: `0.051660%` becomes `0.00051660`. Values are stored as
decimal daily return ratios in `MarketBenchmarkObservation` with provider
`bcb` and benchmark identifier `CDI`.

## Date and precision rules

Performance uses the end-exclusive interval `[from, to)`. BCB requests are
inclusive, so the client maps application intervals explicitly. The client
splits long histories into one-year request chunks, merges them in date order,
and removes duplicate dates without creating synthetic weekend or holiday
rows. A BCB no-values response is an empty result; unrelated HTTP errors remain
failures.

CDI coverage follows the Brazilian banking calendar rather than treating every
weekday as an accrual date. It excludes the fixed national banking holidays and
the movable Carnival Monday and Tuesday, Good Friday, and Corpus Christi dates.
Data health allows one Brazilian banking day for publication: on a weekend the
latest required observation is Thursday, and on Monday the preceding Friday
becomes required.

Daily factors compound in decimal arithmetic. Each intermediate factor is
truncated to 16 decimal places and the final factor is rounded to 8 places,
matching the B3 accumulated-DI convention. The resulting factor minus one is
the CDI return. Summary and chart code use the same benchmark calculation.

`observed_at` records when caramelo retrieved the observation; SGS does not
provide a publication timestamp in this endpoint. A successful HTTP response
can end before the requested final date while the latest rate is unpublished,
so coverage remains explicit in Data health rather than being filled with a
zero or a repeated daily rate. Calculations stop at the latest published rate;
the chart holds that cumulative return flat until the missing observation is
published and the next refresh recomputes it.
