# Data Health

Data health is a read-only diagnostic view over replaceable market data and
derived performance observations. Trades, instruments, institutions, settings,
and backups are durable user data; quotes and current FX are refreshable cache
data, while daily closes, historical FX, benchmark observations, and
performance observations are persisted history.

## Coverage

The report inspects current prices, current FX, daily closes, historical FX,
benchmarks, and portfolio performance. Required dates come from the owner’s
trades and open positions. Historical FX coverage includes both trade settlement
dates and every valuation date on which a foreign-currency position is open.
Trades are ordered by `traded_on, id`, so same-day records remain deterministic.
A weekend or holiday is valued from the latest real observation within the
seven-calendar-day historical window. Synthetic rows are never written. Direct
or inverse FX pairs satisfy the same requirement.

Benchmark calendars remain source-specific. Price benchmarks may carry their
latest real close across a short market closure. CDI requires an observation on
each published Brazilian banking day, excludes its fixed and movable banking
holidays, and allows one banking day for BCB publication. Persisted performance
rows with `missing` status do not count as covered dates.

## Status and Recovery

Entries may be `healthy`, `stale`, `partial`, `missing`, `queued`, `updating`,
`failed`, or `interrupted`. A successful job does not imply healthy data: the
report checks stored observations again. Each recoverable entry carries a
canonical `MarketData::Target`, its provider, and a compact missing range.
Recovery is asynchronous and scoped to the owner; provider failures leave the
previous value untouched.

Historical-FX recovery expands the first missing date by the same seven-day
lookback used by valuation. This lets a weekend valuation retry retrieve the
preceding real market-day rate. A newly persisted FX observation invalidates and
rebuilds the affected portfolio and reporting-currency instrument projections.

Refresh state lives in the cache and is intentionally disposable. It records
progress, run IDs, cooldowns, and terminal errors, so a page reload can explain
active or interrupted work. A unique batch scope coordinates related targets;
the batch count restarts for each accepted run. Coordination and per-instrument
bookkeeping scopes do not compete for space in the user-facing progress
indicator, and completed dynamic scopes are pruned after the interruption
window.

## Fencing and Resets

Publication generations prevent an older worker from writing after a newer
reset. Current and historical FX use a canonical pair scope so inverse pairs
share a fence. Recovery leases allow one active recovery per target and only
the owner token can release it. Reset requests require a signed, expiring
preview whose fingerprint is revalidated before replacement. Data is fetched
and validated before replacement; a failed fetch never deletes the old value.
Accepting a replacement advances the target’s publication fence before the new
work is enqueued, so an older in-flight worker cannot publish over it. Every
unhealthy supported source and derived performance target can expose this same
signed replacement preview.

## Live Updates

Outside Data health, refresh status uses the global transient notification. The
Data health page instead keeps one stable inline activity surface: intermediate
updates morph only its progress counter, so repeated refresh events do not
restart the notification or its motion. It remains active while either a
transient refresh is running or the report still contains a rebuilding derived
source. Meaningful state transitions broadcast a coherent report to each
URL-backed filter stream (`all`, `attention`, and `healthy`). Summary counts,
filter membership, and table rows therefore update together. The report is
built locally from persisted data and cache state; it never calls a provider
while rendering.

## Local Verification

Run focused checks with:

```sh
bin/rails test test/services/market_data/health_report_test.rb
bin/rails test test/services/market_data/health_report_broadcaster_test.rb
bin/rails test:system
```

`bin/ci` also runs RuboCop, Herb, I18n, security audits, Rails tests,
system tests, coverage, and seed verification.
