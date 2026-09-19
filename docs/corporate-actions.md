# Income from corporate actions

caramelo records cash income paid by an instrument as either a dividend or, for BRL instruments, juros sobre capital próprio (JCP). Income belongs to the portfolio owner and one instrument. It may also identify the institution that received the payment.

The instrument determines the income currency. If the owner has traded the instrument through one active institution, caramelo associates that institution automatically. If there are multiple eligible institutions, the form lets the owner choose one. The association remains optional when no institution applies.

## Amounts and withholding tax

Each income entry records a gross amount and optional withholding tax. caramelo calculates the received amount as:

```text
net amount = gross amount - withholding tax
```

Amounts are stored in integer currency subunits. The gross amount must be positive, withholding tax cannot be negative, and tax cannot exceed the gross amount. caramelo does not infer a tax rate; the entered withholding amount is authoritative.

The net amount is shown in income history and is the amount included in after-tax performance.

## Payment date and ex-date

The payment date records when the income reached the account. It is required and is used to order income history.

The ex-date is optional. It records when the instrument began trading without the right to receive the distribution and cannot be later than the payment date. When present, the ex-date is the performance date. Otherwise, the payment date is used:

```text
performance date = ex-date or payment date
```

Using the ex-date aligns the distribution with the related price adjustment. The performance date also determines historical exchange-rate lookup, market-data backfill, and the earliest date rebuilt after an income change.

## Portfolio and instrument performance

Confirmed income is investment return, not an external contribution. It is included in both portfolio and instrument performance as a cash distribution on the performance date.

Income does not:

- buy or sell units;
- change the position quantity;
- change moving-average cost basis; or
- create sale-derived realized gain.

Gain on cost includes net income alongside realized and unrealized gains:

```text
sale realized gain + unrealized gain + net investment income
----------------------------------------------------------------
                    cumulative purchase cost
```

Modified Dietz treats the received income as a withdrawal from the measured investment. This preserves the economic return represented by the distribution while market value continues to represent only the units still held.

## Currency conversion and missing data

Native-currency performance uses the net amount directly. Reporting-currency performance converts the net amount using historical FX for the performance date.

If the required historical exchange rate is unavailable, the affected performance observation is unavailable. caramelo never substitutes a current exchange rate for missing historical data. Saving or updating confirmed income requests the necessary historical data and schedules the affected portfolio and instrument observations for rebuilding.

## Reinvested income

Income and reinvestment are separate events. A dividend or JCP entry always records the distribution as return. If some or all of that money buys units, the purchase is recorded as an ordinary trade.

There is no required one-to-one link between income and a trade because reinvestment may be partial, delayed, combined with other cash, or used to buy a different instrument. Leaving out a purchase keeps holdings unchanged without removing the income from performance.

## Lifecycle, provenance, and recalculation

Corporate actions can be pending, confirmed, ignored, or reversed. Only confirmed actions affect performance. Manual entries are confirmed when saved through the income form.

Each record retains its source and may retain a source reference and raw provider payload for provenance. Those fields identify where the event came from; the normalized corporate action remains the accounting record used by caramelo.

Creating, editing, deleting, confirming, ignoring, or reversing an effective income entry invalidates the independently materialized portfolio and instrument observations from the earliest affected performance date. Rebuild jobs recalculate those derived observations from the durable trade, income, closing-price, and historical-FX records.

## Privacy and deletion

Income amounts follow the application-wide monetary-value visibility setting. When values are hidden, the server renders masked values and income cannot be created or edited until monetary values are shown again.

An instrument, institution, or owner referenced by income cannot be deleted until the related income records are removed. Deleting an income entry removes the durable record and rebuilds the affected derived performance observations.
