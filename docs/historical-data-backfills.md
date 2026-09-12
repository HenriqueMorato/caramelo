# Historical Data Backfills

`HistoricalDataBackfill` is temporary coordination state for historical-data
imports. It is not a market-data table and it does not retain a job history.
The durable observations remain `DailyClosingPrice` and
`HistoricalExchangeRate`, which performance needs to value a past date.

## Request lifecycle

Each request records an `instrument`, its trade `currency`, the earliest
affected `from_date`, and a `generation`. There is one request per instrument
and currency while work is pending.

Creating, editing, or deleting a trade calls
`Trades::HistoricalDataBackfillEnqueuer`. It records the work and queues
`BackfillHistoricalMarketDataJob`; the web request never calls a provider.

The job imports from `from_date` through today in 90-calendar-day batches. It
uses the shared Yahoo throttle before each daily-close or FX request. Yahoo
returns only market dates, so caramelo never creates made-up weekend or
holiday prices.

On completion, the request is deleted. A terminal provider error is reported
and also deletes it, leaving Performance explicitly unavailable. Temporary
transport, rate-limit, and provider-unavailable failures retry through Active
Job before that cleanup happens.

## Coalescing concurrent changes

`instrument` and `currency` form the request's unique key. The first relevant
trade change creates the request and queues a job. Later changes for the same
key reuse that row: a later trade date changes nothing, while an earlier date
moves `from_date` backwards and increments `generation`. Reused requests do
not enqueue another immediate job, so several edits do not create overlapping
provider imports.

At the start of a run, the job locks the row and remembers its `from_date` and
`generation`. It imports that snapshot in 90-day batches. Before deleting the
row, it locks it again:

- an unchanged generation means the request is complete and can be deleted;
- a changed generation means an edit arrived during the import, so the job
  queues one follow-up run and leaves the row in place.

The unique database index handles two web requests trying to create the same
row at once. The losing request retries the lookup and coalesces with the row
that won, rather than adding a duplicate.

## Example

On August 30, adding a VOO purchase dated January 10 creates a request for
VOO/USD from January 10. The job imports VOO daily closes and USD-to-BRL rates
for January 10 through August 30, in bounded batches. A BRL PETR4 trade imports
only PETR4 closes because BRL-to-BRL conversion needs no rate.

If a December 1 VOO trade is added before the January request finishes, the
same request moves back to December 1 and increments `generation`. The running
job finishes its January snapshot, sees the changed generation, and queues one
follow-up run for the December range. While a request exists for an instrument
missing from the report, Performance says that historical data is loading.
