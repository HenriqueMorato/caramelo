# Portfolio Performance Observations

Long performance ranges use `PortfolioPerformanceObservation` as a derived,
durable read model. Trades, daily closing prices, and historical exchange rates
remain authoritative. Deleting every observation is safe because caramelo can
rebuild them from those records.

Each user, reporting currency, and calendar date has at most one row. The row
stores the exact end-of-day portfolio value and cumulative trade cash flow,
along with its source status. Analytical amounts use text-backed decimals so
SQLite cannot round them before Active Record returns a `BigDecimal`.
Two additional text fields retain exact rational cash-flow totals: `cash_flow_total`
is the sum of signed reporting-currency trade amounts; `dated_cash_flow_total`
is the sum of each amount multiplied by its trade date's Julian day number.
These are calculation inputs, not extra money balances or user-facing metrics.

## Read and Build Flow

`Performance::Series` reads the materialization metadata and a complete observation
range in two queries, regardless of the range length. It derives daily gain
or loss and Modified Dietz return in one linear pass from the opening value and
each day's cumulative flow totals. The output still contains every calendar day, including
weekends and market holidays, and never turns a missing value into zero.

For a selected opening day A and endpoint B, subtract their cumulative totals to
obtain `flow` and `dated_flow`. The period's weighted flow is
`(B.jd * flow - dated_flow) / (B.jd - A.jd)`. This is the same sum of dated
trade flows used by `Performance::Period`, without replaying trades for every
chart point. An unavailable day between A and B leaves a chart gap but does not
prevent B's return when both endpoints have complete data. An unavailable opening
day still makes the period return unavailable.

If a date is absent or stale, `Performance::SeriesRefresh` extends the durable
requested range and acquires one cache lease per user/reporting currency before
enqueueing `BuildPortfolioPerformanceObservationsJob`. Week, year, all-time, and
trade-triggered requests coalesce into that same range instead of adding overlapping
jobs. Solid Queue permits one portfolio builder at a time. The builder preloads
trades once, skips fresh dates, and upserts each completed day separately.
Only absent or stale dates extend the request: viewing All after today's price
changes does not turn a one-day refresh into an all-time rebuild.

`PortfolioPerformanceMaterialization` stores `requested_from`, `requested_to`,
and `source_generation`. These are recovery metadata, not financial source records.
The requested bounds retain unfinished work; the generation identifies changes to
the authoritative inputs. A short database transaction checks the generation
before publishing each day. It never holds a lock while calculating that day.

A crash leaves useful progress and a durable request. After the 30-minute cache
lease expires, the next request can enqueue another job even if an old running
status remains cached. Failed builds have a 30-second retry cooldown. Each lease
has a unique owner token; state updates and release check that token under the same
metadata lock, so an expired worker cannot overwrite a newer worker's status or
release its lease. Cache loss may duplicate work, but generation checks and the
database uniqueness constraint protect the results.

## Invalidation

- Creating or deleting a trade invalidates from its trade date.
- Editing a trade invalidates from the earlier of its old and new dates.
- Reassigning a trade invalidates both affected owners.
- Imported price or FX corrections invalidate from the earliest imported date.
  The source rows and dirty metadata commit in one transaction; a failed row
  rolls back the entire import batch.
  FX invalidation considers trades in either currency because valuations may
  use the stored rate directly or invert it.
- A batched historical backfill delays its rebuild enqueue until all batches are
  imported.
- Removing the last trade deletes the derived observations and schedules a cleanup
  pass, preventing an already-running builder from recreating deleted history.
- Existing reporting-currency scopes are all invalidated by source edits. Changing
  reporting currency selects its own observation set without reviving old values.

Trade callbacks persist the dirty generation/range inside the trade transaction,
then enqueue only after commit. Queue failure therefore cannot lose the repair
request or undo a successful financial write. Direct database changes that bypass
callbacks/importers require the rebuild command below.

### An Edit During a Build

Suppose a worker is rebuilding from 15 August to 3 September using generation
7. A trade dated 20 August changes while it is calculating a day:

1. The trade transaction advances the generation to 8 and retains the earliest
   unfinished date. The existing job's lease prevents a second overlapping enqueue.
2. The worker's publication check sees generation 8 and rejects its generation-7
   value. It cannot mark that older result fresh.
3. Completion cannot clear the newer dirty request. After releasing its lease,
   the worker enqueues the remaining coalesced range.
4. The next pass uses generation 8 and clears the request only when that entire
   range is covered and no further source change has arrived.

Stale rows remain available as explicitly labeled last-calculated values while
the background job replaces them. Partial, pending, source-missing, and failed
states remain distinct in the UI.
Partial and failed ranges also disclose when their displayed values are stale.
During a rebuild, opening and endpoint values may belong to different generations.
If either is stale, their derived gain/return stays unavailable until compatible
endpoints exist; the individual known market values remain visible. Different
generations are safe to compare when both endpoints are fresh, such as today's
rebuilt value against an unaffected historical opening.

## Rebuild Command

Rebuild all dates synchronously:

```sh
bin/rails performance:observations:rebuild
```

Limit the repair to a range when investigating a correction:

```sh
FROM=2026-01-01 TO=2026-06-30 bin/rails performance:observations:rebuild
```

The command uses the same lease and completion path as background work, and refuses
to compete with an active build. It prints built versus reused counts. A published
date keeps its exact value; a source change during calculation schedules a follow-up
pass rather than publishing an older snapshot.
With no trades, the builder clears derived observations under the same generation
check. It retains the materialization row so a concurrent new trade cannot lose
its pending rebuild or reset the generation fence.

## Baseline

On 3 September 2026, the development portfolio contained 50 trades and 385
all-time calendar points. The previous request-time implementation measured:

| Range | Points | SQL queries | Wall time |
| --- | ---: | ---: | ---: |
| Week | 8 | 112 | 294 ms |
| Year | 366 | 2,281 | 4,188 ms |
| All time | 385 | 2,393 | 4,223 ms |

Use the same local portfolio after rebuilding to compare the materialized read
path. After adding durable invalidation checks, the rebuilt read measured with
Active Record's query cache disabled:

| Range | Points | SQL queries | Wall time |
| --- | ---: | ---: | ---: |
| Week | 8 | 2 | 2 ms |
| Year | 366 | 2 | 30 ms |
| All time | 385 | 2 | 30 ms |

These are series-read measurements, not full-page timings. They reduce the
all-time calculation from 2,393 queries to two and roughly 4.2 seconds to 30 ms
on the same data, including existing historical gaps. Exact timings vary by
machine; constant query count and formula equivalence are the stable regression
signals. A cold rebuild still replays authoritative valuations in the background;
incremental replay and bounded batching remain possible future optimizations.
