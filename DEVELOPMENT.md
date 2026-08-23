# LocalFolio development

## Requirements

- Ruby 4.0.6 with Bundler
- SQLite 3
- libvips
- Chrome or Chromium for system tests
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

Use `money-rails` for monetary model attributes. Persist amounts as integer
subunits alongside an explicit ISO 4217 currency code: for example,
`price_cents = 12345` and `price_currency = "BRL"` represent BRL 123.45.
Declare record-specific currencies with
`monetize :price_cents, with_model_currency: :price_currency`, and validate
currency columns with `iso_currency: true` after normalizing them to uppercase.

BRL is the application and migration-helper default, but records may explicitly
store other supported currencies such as USD. Never use floating-point columns
for financial values, and never imply that equal subunits in different
currencies have been converted.

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

Preserve unrelated changes. Foundation changes must not introduce financial
domain migrations or behavior.

## Foundation acceptance

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

The production image must boot with only its local `SECRET_KEY_BASE`; it does
not require a Rails master key, market-data credentials, or authentication
credentials. The final acceptance requirement is a green GitHub Actions run on
the Foundation pull request.
