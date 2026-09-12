# Portfolio Performance

`Performance::Portfolio.for(valuation_date:)` calculates the portfolio at one
historical date. `Performance::Period.for(from:, to:)` compares two such
valuations and produces the report shown at `/performance`.

Calculations default to the owner's persisted `reporting_currency` (initially
BRL). An explicit `owner:` keeps another owner's period and valuations scoped
together. Changing the preference does not convert or rewrite stored trades,
instrument currencies, closing prices, or FX history. Missing rates for the
selected currency remain unavailable rather than falling back to BRL values.

Presenters format the currency of the calculated result, not a newly read
preference. Derived chart observations and refresh leases are isolated by owner
and currency; an already queued rebuild keeps its original currency.

Period boundaries use `Date.current` in the application's configured
`America/Sao_Paulo` timezone. Provider observations retain their own persisted
market dates; caramelo does not rewrite them to manufacture a local close.

## Calculation

Trade replay uses the same long-only weighted-average algorithm as Positions.
It keeps quantities, cost basis, and gains as exact ratios internally, exposing
48-significant-digit decimals only at the public boundary. `Money` rounds only
for display.

Each trade is converted to the reporting currency (BRL by default) using its
persisted exchange rate on the trade date. Buy cost plus fees increases basis;
sale net proceeds minus the proportional basis is realized gain. The remaining
market value minus remaining basis is unrealized gain.

For a period, purchases are positive cash contributions and sale proceeds are
negative withdrawals. Gain/loss is:

`closing market value - opening market value - net trade cash flow`.

The return uses Modified Dietz: each flow is weighted by the fraction of the
period remaining after its end-of-day trade date. Deposits, withdrawals, taxes,
and dividends are not modeled yet and must become explicit cash flows before
they can be included in performance.

This is a cash-flow-adjusted **price return**, not a true daily-linked
time-weighted return or total return. It excludes dividends, interest,
withholding tax, and corporate actions. The report's realized and unrealized
gain cards are cumulative through the selected ending date; the headline
gain/loss is specific to the selected period.

## Worked example

For an August reporting period, assume the following USD holding and BRL
reporting currency:

| Date | Event | Calculation | BRL amount |
| --- | --- | --- | ---: |
| Aug 1 | Opening value | 2 shares × USD 105 close × 5.00 USD/BRL | 1,050.00 |
| Aug 16 | Buy | 1 share × USD 110, plus USD 1 fee, × 5.20 USD/BRL | 577.20 |
| Aug 31 | Closing value | 3 shares × USD 120 close × 5.10 USD/BRL | 1,836.00 |

The purchase is a positive period cash flow, not gain. Therefore gain/loss is
`1,836.00 - 1,050.00 - 577.20 = BRL 208.80`.

For Modified Dietz, the 16 August flow has 15 of the 30 period days remaining,
so the weighted capital is `1,050.00 + (577.20 × 15/30) = BRL 1,338.60`.
Return is `208.80 / 1,338.60 = 15.60%`. If shares were sold, their net proceeds
would be a negative cash flow; realized gain would be those proceeds less the
proportional weighted-average basis, while the remaining shares retain the
unrealized component.

## Historical data safety

Performance requires persisted daily closes and FX; it never substitutes a
current cached quote. Exact observations are preferred. A recent observation
can be used only within the seven-calendar-day historical safety window, which
covers weekends and short exchange holidays without allowing indefinitely stale
prices. The report displays **Prices through** using the oldest close date
among open holdings. When a foreign-currency position uses an FX observation
from an earlier date, the report also identifies that FX date so the valuation
remains auditable. Same-currency positions do not have an external FX
observation. Missing data outside that window makes the report explicitly
unavailable.

Non-trading days are resolved per instrument. A Brazilian holding and a US
benchmark do not borrow one another's calendar: each uses its own latest
persisted observation, and charts carry those values independently.

`CaptureDailyClosingPricesJob` and
`CaptureHistoricalExchangeRatesJob` fetch durable Yahoo history in the
background. Their provider failures are reported and do not invent values.
When a trade change requires older observations, [Historical data
backfills](historical-data-backfills.md) coalesce and import that range in the
background. Performance displays a loading state while relevant work is
pending.

## Changing reporting currency

**Settings → Reporting currency** saves the owner's preference for portfolio
totals, performance, and charts. Trades, instrument currencies, fees, and
historical source prices are not rewritten. A missing conversion stays
unavailable; an old BRL result is never relabeled as USD or EUR.

The searchable picker filters names and codes after 150 ms without typing
requests to Yahoo. Arrow keys move through results, Enter selects, and Escape
or Tab dismisses the list without changing the saved selection. A native select
remains available without JavaScript. `ReportingCurrency::SUPPORTED_CODES`
defines the same allowlist used by the picker and server validation: AUD, BRL,
CAD, CHF, EUR, GBP, JPY, NZD, and USD. These have Yahoo-listed FX pairs; this is
a curated application list, not a promise that every cross-pair and historical
date is available. See [Yahoo's currency listings](https://finance.yahoo.com/markets/currencies/).

`SettingsController` saves the preference, then enqueues
`PrepareReportingCurrencyJob` with that exact currency. A request superseded
before execution is skipped. `ReportingCurrency::Preparation` groups the owner's
trades by native currency and prepares each foreign-currency pair:

1. Reuse fresh current FX, otherwise refresh it through the provider throttle.
2. Look for missing historical FX from seven calendar days before the first
   trade through today. The lookback supports weekend and holiday valuation.
3. Reuse existing direct or inverse observations. Fetch missing weekdays in
   batches of at most 60, without inserting synthetic weekend observations.
4. Enqueue a performance-series rebuild in the selected currency. Progress
   counts each prepared currency pair plus this final enqueue step; completion
   of preparation does not mean the queued rebuild has finished.

For example, changing a portfolio with USD trades to EUR prepares USD/EUR
current and historical rates. BRL trades additionally require BRL/EUR. EUR
trades require no conversion. Existing stock-price history is reused, not fetched
again by this workflow.

Provider and rebuild-enqueue failures are retried by the job. Successful FX
observations survive a retry. If initial enqueueing fails, the saved preference
is retained and Settings offers **Save again** to retry. Saving an unchanged
preference can also retry preparation. Unsupported provider pairs remain
explicitly unavailable rather than falling back to another reporting currency.

Settings uses Turbo navigation and submission, including its submit-button state
and validation rendering. Reload and ordinary application links warn before
discarding an edited preference. Turbo Back/Forward restoration cannot be
cancelled; the cached form retains its selection, and the server-rendered saved
currency remains the baseline for detecting unsaved changes when returning.
This draft is temporary browser state, not a saved preference.

## Historical series

`Performance::Series.for(from:, to:)` reads materialized daily portfolio
observations and returns one result per calendar date with the portfolio value,
period gain/loss, return, and availability status. The complete lifecycle,
invalidation rules, recovery behavior, rebuild command, and measured baseline
are documented in [Portfolio performance observations](portfolio-performance-observations.md).

The performance page renders available observations as an interactive Chart.js
canvas with portfolio value and net invested capital lines. The same values,
including returns, remain in an expandable data table for keyboard and screen
reader users. A missing observation marks the series incomplete; it is never
drawn as a zero or replaced with a current quote.

Benchmark chart series use the result contract (`available?`, `missing?`, and
`observations`) and carry each benchmark's latest real observation across
non-trading dates. If a requested range starts during a closure, a prior
observation is used only when it falls inside the seven-day safety window; no
synthetic database rows are created. This is evaluated independently per
benchmark, so markets with different holidays do not share a calendar.

The CDI benchmark is a daily rate series from Banco Central's SGS series 12.
Published percentages are normalized to decimal daily returns once, then
compounded with B3's 16-decimal intermediate truncation and eight-decimal final
rounding. CDI history is kept in the same benchmark-observation store, but its
missing accrual dates are not hidden by the price-series carry-forward rule.
