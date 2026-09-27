# Instrument Performance Observations

Instrument performance is an independently materialized, replaceable projection for one owner, instrument, and reporting currency. It is derived from the same authoritative trades, daily closing prices, historical exchange rates, paid settlement exchange rates, fees, and position calculator as portfolio performance.

Portfolio performance is not assembled from instrument observations. Both projections call `Performance::Portfolio`, but portfolio valuation replays all instruments together while an instrument valuation scopes trades before replay:

```text
Trades + daily closes + historical FX
                  |
         Performance::Portfolio
            /             \
Portfolio observations   Instrument observations
```

This separation is required because portfolio cash flows must be weighted against total portfolio capital. Instrument return percentages are never added or averaged to produce portfolio performance.

## Durable Projection

`InstrumentPerformanceMaterialization` records the requested range and current source generation for one user, instrument, and currency. `InstrumentPerformanceObservation` records one calendar-day result with:

- closing market value;
- remaining cost basis;
- cumulative realized and unrealized gain;
- cumulative net trade cash flow;
- cumulative gross purchase cost (`invested_amount`);
- exact rational cash-flow and dated-cash-flow totals;
- availability, generation, generated-at, and stale metadata.

Analytical monetary values use text affinity so SQLite does not round them before conversion to `BigDecimal`. Cash-flow totals use exact rational serialization. Display `Money` values are rounded only after calculations finish.

The projection is replaceable derived data. Trades remain the durable source of truth.

## Valuation and FX Rules

Each observation replays trades through its valuation date using the long-only weighted-average position calculator.

- Buy fees increase purchase cost and invested capital.
- Sell fees reduce proceeds and realized gain.
- A user-entered settlement exchange rate is authoritative for that trade.
- Without paid FX, trade settlement uses the historical exchange rate eligible for the trade date.
- Daily market value uses the closing price and historical exchange rate eligible for the valuation date.
- Native-currency views do not perform unnecessary FX conversion.

Calendar days use `MarketData::HistoricalObservationWindow` to find the latest eligible close and exchange rate. Weekends and holidays can therefore have projected observations without creating synthetic `DailyClosingPrice` or `HistoricalExchangeRate` rows. A current quote never substitutes for missing historical data.

## Return Methodologies

The instrument graph includes two return series. Modified Dietz is visible by default; Gain on cost is initially hidden and can be revealed from the chart legend. Period selection changes the visible window for both methods.

### Modified Dietz

Modified Dietz answers how the capital performed after accounting for when purchases and sales occurred. For an opening and closing observation:

```text
flow = closing.cash_flow_total - opening.cash_flow_total
dated_flow = closing.dated_cash_flow_total - opening.dated_cash_flow_total
duration = closing_date.jd - opening_date.jd

weighted_flow = (closing_date.jd * flow - dated_flow) / duration
gain = closing.market_value - opening.market_value - flow
return = gain / (opening.market_value + weighted_flow)
```

The opening chart point is zero. A missing or incomparable opening observation leaves Modified Dietz unavailable rather than inventing a value. Generation fencing prevents returns from combining a stale opening with a rebuilt closing observation.

### Gain on Cost

Gain on cost answers how much cumulative profit exists relative to gross purchase spending:

```text
total_gain = cumulative_realized_gain + unrealized_gain
return = total_gain / cumulative_gross_purchase_cost
```

This matches the percentage in Position details. It includes realized outcomes after partial sales, closure, and reopening. A new purchase increases the denominator immediately, so this line may move even if the market price does not. Selecting a shorter period zooms the cumulative series; it does not reset purchase cost at the opening date.

Both return lines are included in the instrument chart. Modified Dietz is visible by default; Gain on cost is initially hidden and can be revealed from the chart legend. The exact-values table exposes both series regardless of graph visibility.

The public explanation at `/performance/methodology` provides a worked example and describes where caramelo uses each method.

## Refresh and Generation Fencing

`Performance::SeriesRefresh` coordinates transient leases while requested ranges and generations remain durable in the materialization row. Instrument lease keys include user, instrument, and reporting currency, allowing different instruments to progress independently while preventing overlapping workers for the same target.

`BuildInstrumentPerformanceObservationsJob`:

1. acquires the target lease;
2. reads the durable requested range and generation;
3. preloads the instrument's trades once;
4. builds only missing, stale, or superseded dates;
5. publishes a date only while its generation remains current;
6. retains completed dates if a later date fails;
7. releases the lease and enqueues a coalesced follow-up request when needed.

Because cumulative invested capital cannot be recovered from the other observation columns, the schema migration purges the replaceable instrument observation projection before adding the strengthened status/amount constraint. Startup preparation then requests fresh source-derived rows. The migration does not invent or backfill business data.

## Invalidation

Invalidation begins at the earliest date whose replay or valuation can change:

- trade create or delete: portfolio plus that instrument;
- trade date change: from the earlier old/new date;
- owner or instrument move: old and new targets;
- paid FX or fee edit: portfolio plus that instrument;
- daily close import or correction: portfolio users plus that instrument;
- historical FX correction: affected portfolio and foreign-currency instrument views, excluding unaffected native views;
- historical backfill completion: relevant portfolio and instrument ranges;
- reporting-currency change: prepare FX, then request the portfolio and every traded instrument in the new currency.

For every traded instrument, startup preparation maintains the unique set of its native currency and the owner's reporting currency from the first trade through today.

## Recovery and Health

Data health reports instrument targets that are pending, stale, partial, missing, or failed. Retry preserves source records and resumes the requested range. Safe reset deletes only derived observations, advances the source generation, and rebuilds from authoritative trades and market history.

Available daily instrument results reconcile to the independently calculated portfolio result using exact analytical amounts before display rounding:

```text
sum(instrument.market_value)   = portfolio.market_value
sum(instrument.realized_gain)  = portfolio.realized_gain
sum(instrument.unrealized_gain)= portfolio.unrealized_gain
```

Return percentages do not reconcile by summing or averaging because each target has its own capital and cash-flow weighting.
