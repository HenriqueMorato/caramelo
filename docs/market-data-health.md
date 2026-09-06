# Data health

Data health is a read-only diagnostic view over replaceable market data and
derived performance observations. Trades, instruments, institutions, settings,
and backups are durable user data; quotes and current FX are refreshable cache
data, while daily closes, historical FX, benchmark observations, and
performance observations are persisted history.

## Coverage

The report inspects current prices, current FX, daily closes, historical FX,
benchmarks, and portfolio performance. Required dates come from the owner’s
trades and open positions. Trades are ordered by `traded_on, id`, so same-day
records remain deterministic. A weekend or holiday is valued from the latest
real observation within the seven-calendar-day historical window. Synthetic
rows are never written. Direct or inverse FX pairs satisfy the same requirement.

## Status and recovery

Entries may be `healthy`, `stale`, `partial`, `missing`, `queued`, `updating`,
`failed`, or `interrupted`. A successful job does not imply healthy data: the
report checks stored observations again. Each recoverable entry carries a
canonical `MarketData::Target`, its provider, and a compact missing range.
Recovery is asynchronous and scoped to the owner; provider failures leave the
previous value untouched.

Refresh state lives in the cache and is intentionally disposable. It records
progress, run IDs, cooldowns, and terminal errors, so a page reload can explain
active or interrupted work. A unique batch scope coordinates related targets;
the batch count restarts for each accepted run.

## Fencing and resets

Publication generations prevent an older worker from writing after a newer
reset. Current and historical FX use a canonical pair scope so inverse pairs
share a fence. Recovery leases allow one active recovery per target and only
the owner token can release it. Reset requests require a signed, expiring
preview whose fingerprint is revalidated before replacement. Data is fetched
and validated before replacement; a failed fetch never deletes the old value.

## Live updates

Refresh status broadcasts a global toast and targeted health-row replacements.
Rows use stable IDs derived from their canonical target scope, allowing Turbo to
replace one row without navigating or rebuilding the whole page. The health
report is built locally from persisted data and cache state; it never calls a
provider while rendering.

## Local verification

Run focused checks with:

```sh
bin/rails test test/services/market_data/health_report_test.rb
bin/rails test test/services/market_data/health_report_broadcaster_test.rb
bin/rails test:system
```

`bin/ci` additionally runs RuboCop, Herb, I18n, security audits, Rails tests,
system tests, coverage, and seed verification.
