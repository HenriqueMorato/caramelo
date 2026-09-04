# LocalFolio

LocalFolio is a local-first, single-user portfolio tracker. It lets you manage
financial institutions, a global instrument catalog, and buy or sell trades,
then derives your current positions from that trade history. It can also fetch
current prices for supported Brazilian and US listings and selected European
UCITS ETFs while keeping your portfolio data on your own machine.

## Run locally with Docker

You only need a Docker-compatible runtime.

1. Create your local environment file:

   ```sh
   cp .env.docker.example .env.docker
   openssl rand -hex 64
   ```

   Paste the generated value after `SECRET_KEY_BASE=` in `.env.docker`. This is
   a local application secret, not a Rails master key. The file is ignored by
   Git and must not be committed.

2. Build the image and create its persistent data volume:

   ```sh
   docker build -t local_folio .
   docker volume create local_folio_storage
   ```

3. Start LocalFolio:

   ```sh
   docker run --rm -p 3000:80 --env-file .env.docker \
     --mount source=local_folio_storage,target=/rails/storage \
     --name local_folio local_folio
   ```

Open <http://localhost:3000>. The container prepares its SQLite databases and
seeds the owner on the first run. Stop it with `Ctrl-C`; the named volume keeps
the data for the next run.

Check a running container with:

```sh
curl --fail http://localhost:3000/up
```

## Owner and current access model

The default owner is `admin@localfolio.com`. To use another address, edit
`LOCALFOLIO_OWNER_EMAIL` in `.env.docker` before the first run. If data already
exists, restart with the new value and seed it explicitly:

```sh
docker exec local_folio bin/rails db:seed
```

Login is not activated for the current single-user application. The dashboard
and Trade Ledger are available without signing in. User, session, password
hashing, and password-reset foundations are present for future use.

## Use the Trade Ledger

- **Institutions** are optional banks, brokers, or custodians associated with a
  trade. Deactivate an institution to remove it from new-trade selectors while
  keeping it in existing history. An institution referenced by a trade cannot
  be deleted.
- **Instruments** are shared catalog entries identified by ticker and exchange.
  Each instrument has one currency. Its currency and the instrument itself
  cannot be removed while trades reference it.
- **Transactions** lists the owner's trades. Add a trade there by choosing an
  instrument, or use **Add trade** on an instrument page to preselect it. Trades
  record buy or sell side, date, quantity, unit price, fees, an optional
  institution, and notes; they can be edited or deleted from their history
  cards.

Trade totals and cost basis remain in the instrument's currency. Current market
values are additionally shown in the configured reporting currency (`BRL` by
default), using a cached Yahoo Finance FX rate for foreign holdings. Missing or
stale rates are shown explicitly; native trade and quote values are unchanged.

## Understand your positions

Open **Positions** to see what remains from your recorded purchases and sales.
Select an instrument to see the same summary beside its complete trade history.

- **Quantity** is the number of units still held after purchases and sales.
- **Average cost** is the weighted-average cost of each remaining unit. Purchase
  fees are included.
- **Cost basis** is the total acquisition cost still assigned to the position.
  It decreases proportionally when part of a position is sold.
- An **Open** position has a positive quantity. A **Closed** position has been
  fully sold and can be included from the Positions page when needed.

Positions are derived from trades and refreshed into a local projection, so
editing or deleting a trade queues an update without changing the source
ledger. Position amounts remain
acquisition costs; current market value is a separate calculation. The
**Performance** page derives realized and unrealized gains, portfolio value,
and cash-flow-adjusted returns from persisted daily closes and historical FX.
See [Portfolio Performance](docs/portfolio-performance.md).

## Current market prices

LocalFolio can refresh the current unit price of B3, NASDAQ, NYSE, and NYSE Arca
instruments, plus UCITS ETFs listed on the London Stock Exchange, Xetra,
Euronext Amsterdam, and Euronext Paris. Use **Refresh prices** on Positions or
**Refresh price** on an instrument. Quotes are cached for 30 minutes; the last
known quote stays visible and is marked stale if it cannot be refreshed. London
prices quoted by the provider in pence are converted to pounds before display.

The Docker image includes the required HTTP transport and needs no market-data
credentials. The Yahoo integration is unofficial and intended for personal
use. Fetched quotes remain in your local replaceable cache and are not shipped
with LocalFolio or exposed as a public data service. You are responsible for
complying with the provider's terms.

## Your data

LocalFolio stores its main application data in the container at
`/rails/storage/production.sqlite3`. The `local_folio_storage` Docker volume
keeps that database when the container stops or is replaced.

To inspect the database with the SQLite console while LocalFolio is running:

```sh
docker exec -it local_folio sqlite3 /rails/storage/production.sqlite3
```

Use SQLite's backup command to create a consistent snapshot, then copy it from
the container to the current host directory:

```sh
docker exec local_folio sqlite3 /rails/storage/production.sqlite3 \
  ".backup '/tmp/local_folio-backup.sqlite3'"
docker cp local_folio:/tmp/local_folio-backup.sqlite3 ./local_folio-backup.sqlite3
```

The extracted `local_folio-backup.sqlite3` file can be moved to any backup
location you choose. No external database, cache, queue, market-data
credentials, or authentication service is required. Refreshing a supported
current price makes an outbound request to Yahoo Finance.

The interface is English, the application time zone is
`America/Sao_Paulo`, and future portfolio reporting defaults to Brazilian real
(`BRL`).

## Development

For native Ruby setup, tests, security checks, contribution conventions, and
the complete Trade Ledger acceptance commands, see
[DEVELOPMENT.md](DEVELOPMENT.md).
