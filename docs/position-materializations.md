# Position materializations

Trades remain the source of truth. A `PositionMaterialization` is a replaceable,
owner-and-instrument projection of the same weighted-average replay: quantity,
analytical cost basis, average unit cost, and realized gains.

## Refresh flow

Creating, editing, deleting, or moving a trade enqueues
`RefreshPositionMaterializationJob`. The callback advances `source_generation`
and marks an existing projection pending. The job replays trades in
`traded_on, id` order outside the row lock, then publishes atomically only when
the generation it read is still current. A newer trade therefore cannot be
overwritten by an older worker. Failed replays retain their error and the last
successful values.

Normal position reads use a completed projection when available. Until the
first rebuild, or for historical (`as_of`) calculations and institution-aware
views, the application replays the authoritative trades directly.

## Rebuilding

Rebuild every traded instrument with:

```sh
bin/rails position_materializations:rebuild
```

The task is safe to run repeatedly and can also rebuild one instrument through
`PositionMaterializations::Rebuild.call(user:, instrument:)`.
