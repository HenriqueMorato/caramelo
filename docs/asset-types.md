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
and a name that produces an already-used key must be changed before it can be
saved.

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

The migration creates the empty catalog and removes the old database check that
limited instruments to six keys. It does not backfill rows during migration.
`AssetType.ensure_defaults!` runs from startup refresh and seeds, so an existing
database gets the built-in rows when the application starts. Existing
instruments retain their current keys and immediately resolve to the matching
built-in labels.

The catalog is replaceable metadata around durable instruments. Removing a
custom type is intentionally blocked while it is referenced. This preserves the
meaning of existing instruments and their derived positions and performance
history.
