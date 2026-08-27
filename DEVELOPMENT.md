# LocalFolio development

## Dev Container setup

The Dev Container is the simplest way to get the complete development
environment, including Ruby, SQLite, Chrome, and the HTTP transport used for
market-price refreshes. Install Docker, VS Code, and the VS Code Dev Containers
extension, then open this checkout:

```sh
code .
```

Run **Dev Containers: Reopen in Container** from the command palette. The first
build installs dependencies, prepares the database, and seeds the owner. In the
container terminal, start Rails and Tailwind:

```sh
bin/dev
```

Open <http://localhost:3000>. Application files and the development SQLite
database remain in the checkout, so rebuilding the container does not remove
your data. Run `bin/rails test:system` inside the container to use its Selenium
service. After changing `.devcontainer/Dockerfile`, run **Dev Containers:
Rebuild Container**.

### Without VS Code

The same environment works directly through Docker Compose; no editor plugin
or Dev Container CLI is required. From the repository root, build and start the
development and Selenium containers:

```sh
docker compose -f .devcontainer/compose.yaml up --build --detach
docker compose -f .devcontainer/compose.yaml exec rails-app bin/setup --skip-server
docker compose -f .devcontainer/compose.yaml exec rails-app bin/rails db:seed
docker compose -f .devcontainer/compose.yaml exec rails-app bin/dev
```

Leave the last command running and open <http://localhost:3000>. Use another
terminal for Rails commands and tests, for example:

```sh
docker compose -f .devcontainer/compose.yaml exec rails-app bin/rails test
docker compose -f .devcontainer/compose.yaml exec rails-app bin/rails test:system
```

Stop the containers when finished; this does not delete the SQLite database in
the checkout:

```sh
docker compose -f .devcontainer/compose.yaml down
```

## Native requirements

- Ruby 4.0.6 with Bundler
- SQLite 3
- libvips
- Chrome or Chromium for system tests
- `curl_chrome146` for live Yahoo Finance quote refreshes
- Docker-compatible runtime for production-image verification

## Native setup

Install dependencies and prepare the development database:

```sh
bin/setup --skip-server
bin/rails db:seed
```

The seed is idempotent. It creates the configured owner only when that user is
missing, so repeated preparation does not create duplicates.

Start Rails and the Tailwind watcher:

```sh
bin/dev
```

Open <http://localhost:3000>. To rebuild the development database, run:

```sh
bin/setup --reset --skip-server
bin/rails db:seed
```

The owner defaults to `admin@localfolio.com`. Override it in the shell before
seeding and starting the application:

```sh
export LOCALFOLIO_OWNER_EMAIL=owner@example.com
bin/rails db:seed
bin/dev
```

An ignored `.envrc` with that export can be used when working with `direnv`.
Future owner-scoped records should resolve their user through `User.owner`.

Login is intentionally inactive during the single-user phase. Authentication
models, routes, password hashing, and reset behavior remain covered for future
activation, while application pages stay public.

## Current market prices

LocalFolio uses the Yahoo Finance chart endpoint for current B3 quotes. This is
an unofficial, credential-free integration intended for personal use. Provider
traffic is isolated under `lib/market_data/yahoo_finance`, while application
code uses the provider-neutral classes under `app/services/market_price`.

The Dev Container and production image already include the required transport.
Native development requires `curl_chrome146` from
[`lexiforest/curl-impersonate` v2.1.1](https://github.com/lexiforest/curl-impersonate/releases/tag/v2.1.1).
Download the archive matching `arm64-macos` or `x86_64-macos`, verify its
SHA-256 digest against the immutable GitHub release, then install
`curl-impersonate` and `curl_chrome146` together in a directory on `PATH`:

```sh
tar -xzf curl-impersonate-v2.1.1.<architecture>-macos.tar.gz
install curl-impersonate curl_chrome146 /usr/local/bin/
curl_chrome146 --version
```

Set `YAHOO_FINANCE_HTTP_EXECUTABLE` when the wrapper is installed elsewhere. A
missing executable does not prevent Rails from booting; quote refreshes fail
explicitly and any stale cached quote remains available.

Never commit or redistribute fetched market data. Each operator is responsible
for complying with the market-data provider's terms. Tests must stub the
transport and must not call the live endpoint.

For the class responsibilities, public entry points, cache states, and complete
read and refresh flows, see
[Current Market Price Architecture](docs/current-market-prices.md).

## Quality and security

Run the repeatable local pipeline:

```sh
bin/ci
```

It prepares the application, runs RuboCop, audits Ruby and importmap
dependencies, scans with Brakeman, runs Rails and browser system tests, and
verifies test seeds. Individual commands are available when working on a
focused change:

```sh
bin/rails test
bin/rails test test/models/user_test.rb
bin/rails test test/models/user_test.rb:10
bin/rails test -i /owner/
bin/rails test:system
bin/rubocop
bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
bin/bundler-audit
bin/importmap audit
```

GitHub Actions runs lint, Ruby and JavaScript security scans, unit tests, and
system tests for pull requests and pushes to `main`.

## Internationalization

English translations are split by concern under `config/locales/en/`; Rails
loads locale YAML files recursively. Keep generic reusable strings under the
locale root and use absolute lookups such as `t("actions.Cancel")`. Use lazy
lookup for view-specific copy, with concise human-readable keys such as
`t(".No trades yet")` rather than abstract labels.

Use `activerecord.models` and `activerecord.attributes` for model and form
names. Interpolate models, records, and other changing values instead of
assembling translated fragments. Ordinary translations remain escaped; only a
translation that intentionally contains markup may use an `_html` suffix or an
`html` key.

Check locale health while editing translations:

```sh
bin/i18n-tasks health
bin/i18n-tasks missing
bin/i18n-tasks unused
bin/i18n-tasks normalize
```

The health check rejects missing, unused, inconsistent, or unnormalized keys
and runs as part of `bin/ci`. Development and test raise immediately when a
rendered translation is missing.

## Money and currencies

Use `money-rails` for monetary model attributes. Persist settled amounts such
as fees as integer subunits alongside an explicit ISO 4217 currency code: for
example, `fees_cents = 12345` and `currency = "BRL"` represent BRL 123.45.
Declare record-specific currencies with
`monetize :fees_cents, with_model_currency: :currency`, and validate currency
columns with `iso_currency: true` after normalizing them to uppercase.

Trade quantities and unit prices are precise decimals, never floats. Unit
prices support eight decimal places because an asset price may need more
precision than its currency's smallest subunit. Calculated totals return
`Money` in the trade's currency.

Derived financial values distinguish exact analytical decimal amounts from
currency-rounded `Money`. Use `*_amount` values for calculations and `Money`
values for conventional currency display. Individually rounded trade totals may
differ from an exact aggregate rounded once; neither is broker-confirmed cash.
Position calculations preserve basis as an exact ratio internally and convert
to a 48-significant-digit decimal only at the public boundary. Currency display
uses Money's half-up rounding and must never feed back into position arithmetic.

BRL is the application and migration-helper default, but records may explicitly
store other supported currencies such as USD. Never use floating-point columns
for financial values, and never imply that equal subunits in different
currencies have been converted.

## Position calculation conventions

Positions are derived on read from the configured owner's trades; there is no
persisted position snapshot. Replay trades chronologically by `traded_on`, then
`id` for a deterministic same-day tie-break:

- A purchase adds its quantity, precise `quantity * unit_price`, and purchase
  fee to the position basis.
- A partial sale removes quantity and the same proportion of the existing
  basis. Its price and fee do not change the remaining average cost.
- A full sale resets quantity, basis, and average cost to zero. A later purchase
  starts a new average.
- A sale that would make quantity negative is invalid long-only data and must be
  presented clearly without hiding unaffected positions or trade history.

Keep basis as an exact ratio while replaying trades. Convert it to a
48-significant-digit `BigDecimal` for analytical values and round only the
display `Money` to the instrument currency. Do not sum individually rounded
trade totals to calculate a position. Current price, market value, returns,
realized gains, and FX conversion are outside the Positions milestone.

Run focused position verification with:

```sh
bin/rails test test/models/position_test.rb
bin/rails test test/controllers/positions_controller_test.rb \
  test/controllers/instruments_controller_test.rb
bin/rails test test/system/positions_test.rb \
  test/system/instruments_test.rb
```

## Current market price cache

`CurrentMarketPrice` represents a replaceable intraday unit price. Keep its
unit price as a normalized precise-decimal string in cache and convert it back
to `BigDecimal`; never serialize a financial value as a float. Multiply the
precise unit price by the precise position quantity before constructing
currency-rounded `Money` for display.

`CurrentMarketPriceCache` stores one versioned entry per provider and instrument.
By default, a quote is fresh for 30 minutes. It has no application-level
expiration: the last known quote remains available as stale fallback until it
is replaced or the cache evicts it. Consumers must distinguish `fresh`, `stale`,
and `missing` entries. Cache loss is safe because trades never depend on quotes
and providers can fetch them again.

Provider adapters must return a quote in the instrument's ISO currency, keep
HTTP behavior outside these cache objects, and stub all network traffic in
tests. Use the cache refresh API so fresh values skip provider work. Coordinate
concurrent refreshes in provider jobs rather than this replaceable value cache.

`MarketPrice::Service.default` owns the active provider strategy. Callers do
not select or pass providers. The Yahoo adapter currently supports only B3
listings (`BVMF`), and provider-specific errors must be translated into
application-level failures before reaching jobs or controllers.

## Trade Ledger model conventions

- Resolve the single owner through `User.owner`. Scope institutions and trades
  through that owner; never accept a request-supplied user ID.
- Instruments form a global catalog. Identify a listing by its normalized
  exchange and ticker, and derive a trade's currency from its instrument.
- Institutions are optional on trades. Only active institutions appear for new
  selections, but inactive institutions remain visible on historical trades.
- Keep trades durable. Restrict deletion of referenced institutions and
  instruments, and prevent an instrument's currency from changing after its
  first trade.
- Keep current market quotes out of the ledger. They are replaceable cache data
  until a later milestone explicitly models daily history.

## Contribution workflow

1. Start from an issue with agreed scope and acceptance criteria.
2. Create a type-prefixed branch such as `feat/4-navigation-shell`,
   `fix/12-owner-resolution`, `test/6-single-user-smoke-tests`,
   `docs/7-development-guide`, `chore/5-docker-runtime`, or `ci/9-cache`.
3. Use a matching Conventional Commit and pull-request title, for example
   `test: expand single-user smoke coverage`.
4. Keep each commit focused and include `Closes #<issue>` in the pull-request
   body.
5. Run relevant local checks and wait for every required GitHub check to pass
   before merging.

Preserve unrelated changes. Keep changes within their issue's agreed milestone
and acceptance criteria.

## Trade Ledger and Positions acceptance

Run the complete local acceptance pass:

```sh
bin/setup --skip-server
bin/rails db:seed
bin/ci
docker build -t local_folio .
```

Follow the Docker instructions in [README.md](README.md), then verify the
production container and configured owner:

```sh
curl --fail http://localhost:3000/up
docker exec local_folio bin/rails runner \
  'abort "owner mismatch" unless User.owner.email_address == Rails.application.config.x.local_folio.owner_email; puts "owner: ok"'
```

Create an institution, instrument, and trade through the production interface,
open **Positions**, and record its quantity, average cost, and cost basis. Restart
the container with the same `local_folio_storage` volume, then confirm the trade
and derived position remain unchanged. This proves the authoritative trade data
survives and the position can be reconstructed; positions are not separate
durable records.

The production image must boot with only its local `SECRET_KEY_BASE`; it does
not require a Rails master key, market-data credentials, or authentication
credentials. The final acceptance requirement is a green GitHub Actions run on
the milestone-closing pull request.
