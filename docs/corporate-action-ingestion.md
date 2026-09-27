# Corporate-Action and Income Ingestion

caramelo keeps imported market events separate from the financial ledger until
the owner reviews them. A provider scan creates `CorporateActionImport` rows;
only an explicit confirmation creates the authoritative `CorporateAction` row.
Ignored, failed, and superseded candidates retain their provider payload for
later audit and retry.

```text
Yahoo Finance event payload
          ↓ bounded, explicit scan
CorporateActionImport (review queue)
          ↓ select one or many, then confirm
CorporateAction (authoritative ledger)
          ↓ existing callbacks
positions and performance rebuilds
```

## Historical Scans

Historical ingestion is opt-in. The review page asks for a date range and an
optional traded instrument. The suggested range is the first trade through
today, but it can be narrowed before the scan starts. A scan never confirms a
candidate or changes positions by itself.

The review list keeps source, stable provider reference, exchange-aware symbol,
event date, provider amount or ratio, warnings, and the complete raw payload.
The owner can select all confirmable rows, select individual rows, or select
none. Dividend candidates normally need a payment date and the total credited
amount because Yahoo reports a per-share discovery amount. A Brazilian
dividend may be changed to JCP during review; `CorporateAction` still enforces
the BRL rule and all amount checks. Split and reverse-split candidates can be
confirmed once their ratio and effective date are present.

Bulk confirmation runs one transaction per row. A failed dividend does not
roll back a successful split, and the result reports confirmed, duplicate,
failed, and skipped rows. Re-running a scan is idempotent: the owner/source/
provider-reference key updates unresolved candidates without creating
duplicates. Reviewed accounting fields are preserved while a scan refreshes
provider metadata. A payload correction after review becomes a conflict for
explicit review; confirming the reviewed correction updates the existing
authoritative event instead of creating a second event. If an authoritative
event is deleted, its import is reopened as pending so the owner can confirm it
again.

## Provider Identity and Matching

The Yahoo adapter uses the existing exchange-aware ticker and MIC mapping. It
never creates an instrument from provider data. Scans only request events for
instruments already traded by the owner. For each instrument, the provider
range starts no earlier than its first trade, and candidates dated while the
owner held zero units are ignored. Existing review records are left intact so
this cleanup never discards an item the owner has already reviewed. An
institution is auto-selected only when exactly one institution is associated
with that instrument. Multiple
institutions mark an import ambiguous and block confirmation until the owner
selects the institution in the review form.

Data health keeps ignored imports in a separate review-queue card while any
remain. Its review link opens the import list filtered to ignored rows, so an
earlier decision can be revisited without starting another scan. During a scan,
a provider candidate also receives a `possible_duplicate` warning when a
non-reversed manual event already has the same instrument, event/payment date,
and action type. The candidate stays in the review queue; the warning prevents
an accidental second confirmation without discarding the provider payload.

Yahoo chart events provide dividend/ex-date and split data, but not a reliable
payment date, withholding tax, JCP classification, institution, or credited
total. Those accounting fields remain in review until the owner supplies them.
The review form pre-fills a missing payment date with the
provider event/ex-date and estimates a missing gross total from the quantity
held on that event date multiplied by Yahoo's per-share amount. Both values are
explicitly provisional and remain editable; confirmation uses only what the
owner submits.
The raw response and normalized candidate are retained for every queued
candidate, while malformed provider responses are reported as scan errors and
never become ledger records.

## Confirmation and Recovery

Confirmation builds a normal `CorporateAction` with the same validations and
provenance constraints as a manually entered event. Existing corporate-action
callbacks invalidate historical data and enqueue the usual position and
performance rebuilds. Repeated confirmation is a duplicate no-op. Ignoring an
import does not create an accounting record. Failed rows remain visible with
their error message and can be edited and retried; provider failures do not
delete confirmed actions.

The review page is available at `/corporate-action-imports`. Transactions shows
a discreet review banner only while pending, ambiguous, or conflicted imports
exist; it stays out of the way when the queue is empty. Provider requests in
tests use recorded response objects; no live Yahoo request is required to
exercise parsing, matching, idempotence, or confirmation behavior. A manual
scan is queued immediately and the page keeps its selected range, source, and
instrument while it subscribes to that scan's private status stream. The page
reloads once the complete scan has persisted all candidates; it does not show
partial results or refresh after each provider event. A retryable provider
failure keeps the scan active until Active Job exhausts its retries. A terminal
failure does not trigger a partial page refresh and offers a retry link; any
candidates persisted before the provider error remain reviewable. Scans for
different instruments can run independently, while overlapping scans for the
same owner, source, and instrument share a concurrency lease. The job uses the
same bounded, strict service as synchronous callers.
