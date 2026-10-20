# Asset Types

Asset types are the small catalog used to organize instruments throughout
caramelo. The catalog is global because instruments are global records. An
instrument keeps its asset type as a stable string key, while `AssetType` owns
the label shown to people.

## Built-In and Custom Types

The catalog starts with six built-in types:

- Stock
- ETF
- Fund
- Bond
- Crypto
- Other

Built-in names can be edited when the default wording does not fit a portfolio.
They cannot be deleted. A custom type can be added from **Data health → Manage
asset types**. Custom types can be deleted only while no instrument uses them.
The server checks this rule as well as the UI, so a stale page cannot remove a
category that has become used.

The name is the editable part. When a custom type is created, caramelo derives a
lowercase key such as `real_estate` from the name. The key never changes when
the name is renamed. Existing instruments therefore keep their category and
their historical performance grouping after a rename. Names must be unique,
and names without a Latin transliteration receive a stable opaque ASCII key so
they can be used without changing the displayed label.

## Where Labels Appear

The current label is used in:

- the instrument form;
- the instrument header;
- position grouping by type;
- allocation pie charts;
- performance asset-type lines; and
- Data health descriptions for asset-type performance.

The portfolio and instrument performance projections remain independent. A
custom category changes the grouping label and chart color, but it does not
change trade replay, valuation, cash-flow weighting, or the portfolio return.

## Colors

The six built-in categories use the semantic Caramelo palette. Custom types use
the same 20-color light and dark palette as position allocation charts. The
color is selected from the stable key, so a rename keeps the same color and a
page reload does not reshuffle the chart. Light mode uses the light palette and
dark mode uses its paired dark palette.

## Startup and Existing Data

The migration creates the catalog, seeds the six built-in rows needed by the
foreign key, and replaces the old database check that limited instruments to
six keys. Existing instruments retain their current keys and immediately
resolve to the matching built-in labels. The catalog accepts up to 100 custom
types so public single-user mode cannot grow an unbounded option list.

Stop all web and job processes while applying this migration. Older workers
still use the six-value enum and must not overlap the release that can write a
custom key.

The catalog is durable metadata around durable instruments and is included in
ledger backups. Removing a custom type is intentionally blocked while it is
referenced. This preserves the meaning of existing instruments and their
derived positions and performance history. Each type's stable key is also used
as its friendly management-route identifier, so renaming a display label does
not invalidate existing links.
