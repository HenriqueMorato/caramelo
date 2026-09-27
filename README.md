<p align="center">
  <img src="app/assets/images/caramelo-logo.svg" alt="caramelo" width="112">
</p>

# caramelo

Your investments, without sending your portfolio somewhere else.

`caramelo` is a local-first portfolio tracker for one owner. Record trades,
follow positions, compare native and reporting-currency values, and explore
historical performance while keeping the primary ledger on your own machine.

## What You Can Do

- Keep a precise buy-and-sell ledger with fees, institutions, notes, and paid FX.
- Follow open and closed positions with weighted-average cost basis.
- Track current prices for supported Brazilian, US, and European listings.
- Review portfolio and per-instrument performance from persisted daily history.
- Compare portfolio returns with Ibovespa, S&P 500, and CDI benchmarks.
- Review provider-sourced dividends and corporate actions before confirmation.
- See missing or stale market data and safely retry replaceable projections.
- Create verified local backups and export the trade ledger as CSV.
- Switch between light, dark, and system appearance.

## Run caramelo with Docker

You need [Docker Desktop](https://www.docker.com/products/docker-desktop/),
[OrbStack](https://orbstack.dev/), or another Docker-compatible runtime with
Docker Compose.

From the repository root, run:

```sh
docker compose up --build
```

Then open <http://localhost:3000>.

That one command:

1. builds the production image;
2. creates persistent volumes for application data and verified backups;
3. generates a private application secret on the first run;
4. prepares the SQLite databases and seeds the default owner;
5. starts the web application and the Solid Queue worker.

The first build can take a few minutes. When `web` is healthy and `jobs` is
running, caramelo is ready. No environment file is required for the default
local setup.

Press `Ctrl-C` to stop the foreground stack. Your records remain in Docker
volumes, so the next start is simply:

```sh
docker compose up
```

### Useful Docker Commands

| Task | Command |
| --- | --- |
| Start in the background | `docker compose up --build --detach` |
| Check web and worker status | `docker compose ps` |
| Follow application and queue logs | `docker compose logs --follow web jobs` |
| Check application health | `curl --fail http://localhost:3000/up` |
| Stop caramelo | `docker compose down` |
| Open a Rails console | `docker compose exec web bin/rails console` |

`docker compose down` removes containers and the private network, but keeps
the named volumes. Do not add `--volumes` unless you intentionally want to
delete the local application data and backups.

### Optional Configuration

The built-in owner identifier is `admin@caramelo.local`. To choose another
address for a fresh install, copy the example before the first run:

```sh
cp .env.docker.example .env.docker
```

Edit `CARAMELO_OWNER_EMAIL` in `.env.docker`, then start the stack. Existing
installations keep resolving the previous owner automatically, and legacy
environment variables remain supported during the rename. The ignored
environment file may also hold a manually managed `SECRET_KEY_BASE`, but
caramelo normally creates and retains one inside its private storage volume.

To use another host port without editing a file:

```sh
CARAMELO_PORT=8080 docker compose up --build
```

The default bind address is `127.0.0.1`, so the unauthenticated application is
reachable only from the Docker host. To allow another trusted device on your
network to connect, opt in explicitly:

```sh
CARAMELO_BIND_ADDRESS=0.0.0.0 docker compose up --build
```

Do not expose that address to an untrusted network while login remains inactive.

## Your Data Stays Local

The Compose stack uses two named volumes:

- `caramelo_storage` contains the SQLite application, cache, queue, and cable
  databases, plus the generated application secret.
- `caramelo_backups` contains verified backup runs.

The browser does not upload your ledger to a caramelo service. Refreshing
supported prices, exchange rates, or benchmarks makes outbound requests to the
documented market-data providers. Current quotes and historical observations
are replaceable data; trades remain the durable source of truth.

Login is intentionally inactive during the current single-user phase. Anyone
who can reach the running web port can access the portfolio, so bind or expose
that port only on a network you trust.

### Back Up and Export

Create and verify a backup from the running stack:

```sh
docker compose exec web bin/backup create
BACKUP_DIRECTORY=2026-09-10T120000.000000Z
docker compose exec web bin/backup verify "/rails/backups/$BACKUP_DIRECTORY"
```

Replace the example directory name with the `Directory:` value printed by the
create command.

Copy the backup directory to protected off-host storage as part of your own
backup routine:

```sh
docker compose cp web:/rails/backups ./caramelo-backups
```

Backup artifacts contain private financial information. The Data health page
also lets you create or verify a backup and download the trade ledger as CSV.
See [development and operations](DEVELOPMENT.md#sqlite-backups) for retention,
restore rehearsal, and safe pruning details.

## How the Portfolio Works

Trades are authoritative. Positions are derived from those trades using exact
decimal quantities and weighted-average cost basis. Buy fees increase cost;
sell fees reduce realized proceeds. Native-currency values remain native, while
reporting views use the appropriate paid, trade-date, or valuation-date FX rate.

Performance is materialized asynchronously from trades, daily closing prices,
and historical FX. Missing historical data stays visibly unavailable. Current
quotes never masquerade as historical closes. Portfolio and instrument return
series are calculated independently because their cash flows have different
capital weights.

Read more:

- [Portfolio performance](docs/portfolio-performance.md)
- [Instrument performance](docs/instrument-performance-observations.md)
- [Current market prices](docs/current-market-prices.md)
- [Historical exchange rates](docs/historical-exchange-rates.md)
- [Corporate-action ingestion](docs/corporate-action-ingestion.md)
- [Data health and recovery](docs/market-data-health.md)

## Support caramelo

caramelo is independent and local-first. If it helps you keep your portfolio in
order, you can [support its development on Ko-fi](https://ko-fi.com/henriquemorato).

## Develop caramelo

For a native setup:

```sh
bin/setup --skip-server
bin/rails db:seed
bin/dev
```

Open <http://localhost:3000>. Run the full local verification pipeline with:

```sh
bin/ci
```

Ruby, Node, SQLite, browser-test, Dev Container, and focused-test instructions
are in [DEVELOPMENT.md](DEVELOPMENT.md).
