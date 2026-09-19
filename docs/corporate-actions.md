# Corporate actions

caramelo uses one durable `CorporateAction` domain for dividends, Brazilian juros sobre capital próprio (JCP), splits, reverse splits, bonifications, and rights. The shared record owns identity, instrument, payment date, review state, source provenance, and audit context. Type-specific services apply either a cash-distribution effect or a quantity-and-basis effect.

Issue #109 introduces cash dividends and JCP. Issue #110 extends the same table with quantity-changing actions. Issue #116 adds provider ingestion and review after both accounting paths are authoritative.

## Lifecycle and provenance

Only confirmed actions affect positions or performance. Pending actions may be reviewed and reclassified; ignored and reversed actions have no active financial effect. Manual records use the `manual` source. Provider records retain a source reference and raw payload so an imported event can be audited without making the provider payload itself the accounting authority.

## Cash distributions

Cash dividends and JCP store gross amount, withholding tax, and net amount in integer currency subunits. The database and model both require:

```text
net amount = gross amount - withholding tax
```

The net amount is the cash received and the amount used for after-tax performance. caramelo never guesses a tax rate. JCP remains a distinct action kind so reporting can separate it from dividends without hardcoding tax treatment.

Cash income does not buy or sell units, change moving-average cost basis, or create sale-derived realized gain. Payment date is the day the income reached the account and remains the cash-history date. An optional ex-date identifies when the instrument began trading without the distribution. Performance recognition, historical FX, backfill, and rebuild invalidation use the ex-date when present and otherwise fall back to payment date.

## Reinvestment

The corporate action always records the dividend or JCP as investment return. There is deliberately no reinvestment field or foreign key to a trade: reinvestment can be partial, delayed, pooled with other cash, or used to purchase a different instrument, so a forced classification or one-to-one link would misstate the financial event. When the investor wants caramelo to reflect acquired units and their cost basis, they record an ordinary purchase independently. Omitting that purchase leaves holdings unchanged but does not remove the income from return calculations.

## Quantity actions

Stock dividends and Brazilian bonifications are quantity actions rather than zero-value cash income. Issue #110 adds ratios, fractional entitlements, cash-in-lieu, and the replay rules shared with splits, reverse splits, and rights. These calculations remain separate from cash-distribution calculations even though the events share one table and timeline.

## Performance and FX

Cash income is investment return rather than an external contribution. Performance treats net income as a distribution leaving the currently modeled holdings, allowing total return to include the payout while market value remains limited to held instruments.

Foreign-currency income uses historical FX on the performance date (`ex_date || paid_on`). Missing historical FX makes the affected calculation unavailable; current FX is never substituted. Income does not alter quantity, remaining basis, or sale-derived realized gain. Gain on cost includes net income separately:

```text
(sale realized gain + unrealized gain + net investment income)
----------------------------------------------------------------
                    cumulative purchase cost
```

Provider imports never become effective silently. Issue #116 will normalize provider data into reviewable actions, deduplicate by source reference, preserve the raw payload, and require confirmation before applying financial effects.
