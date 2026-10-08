# Global All-Cap Benchmark

caramelo includes an **MSCI ACWI IMI Net Total Return USD** comparison. The
[MSCI ACWI Investable Market Index](https://www.msci.com/indexes/index/664204/msci-acwi-imi-index)
covers large-, mid-, and small-cap companies across developed and emerging
markets. It is a global equity comparison, not a cash return or risk-free rate.

## Total-Return Convention

The seeded benchmark is classified as **net total return**. MSCI's reference
variant assumes distributions are reinvested after withholding taxes, while
the accumulating tracker includes reinvested distributions after fund costs.
Both capture price movement and distributed income. The convention is stored on
the benchmark definition rather than inferred from its display name. A future
gross total-return or price variant can therefore be added without changing
portfolio calculations.

Yahoo Finance does not expose a usable daily history for the direct MSCI index
code. The seeded definition therefore uses `IMID.L`, the [USD-traded,
accumulating SPDR MSCI ACWI IMI tracker](https://www.ssga.com/uk/en_gb/intermediary/etfs/state-street-spdr-msci-all-country-world-investable-market-ucits-etf-acc-spyi-gy),
as a historical proxy for the same index universe. Its accumulating price
includes reinvested distributions after fund costs, so the comparison is a net
total-return proxy rather than a direct MSCI index feed. Each persisted
observation keeps the benchmark, provider, source date, currency, and retrieval
timestamp. caramelo does not turn a current quote into a historical point.

## Performance Comparison

The benchmark is available in the Performance chart's legend alongside the
portfolio, Ibovespa, S&P 500, and CDI. Click a legend item to show or hide a
series. Benchmark returns compare the first and last available index levels
in the selected period; CDI compounds its daily rate observations separately.
When the portfolio reports in another currency, each index observation is
converted with the historical rate eligible for that observation date before
the return is calculated. A missing conversion keeps the benchmark unavailable.
Portfolio returns remain independently calculated with Modified Dietz and are
never reconstructed by adding or averaging benchmark or instrument returns.

Benchmark calendars are source-specific. A real index observation may be
carried across a short weekend or market closure only within the existing
historical safety window. Interior gaps and unavailable history remain visible
in Data health and are never filled with a current quote or a synthetic row.

## Source and Availability

The scheduled market-data capture job audits all configured benchmarks from the
owner's earliest activity through the latest eligible trading date. Data health
reports missing, partial, stale, unsupported, and failed benchmark history and
offers the same scoped retry and replace-data safeguards as other replaceable
market data. It also checks the historical FX needed to compare a foreign
benchmark in the selected reporting currency. Provider outages leave
previously stored observations untouched.

The index is maintained as a first-class `MarketBenchmark`, so a later FTSE
Global All Cap or another explicitly documented global series can be added as a
separate definition. That preserves the source and return convention instead
of silently replacing one benchmark with another.
