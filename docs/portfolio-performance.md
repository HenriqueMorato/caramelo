# Portfolio Performance

`Performance::Portfolio.for(valuation_date:)` calculates the portfolio at one
historical date. `Performance::Period.for(from:, to:)` compares two such
valuations and produces the report shown at `/performance`.

Period boundaries use `Date.current` in the application's configured
`America/Sao_Paulo` timezone. Provider observations retain their own persisted
market dates; LocalFolio does not rewrite them to manufacture a local close.

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
among open holdings. Missing data outside that window makes the report
explicitly unavailable.

`CaptureDailyClosingPricesJob` and
`CaptureHistoricalExchangeRatesJob` fetch durable Yahoo history in the
background. Their provider failures are reported and do not invent values.
