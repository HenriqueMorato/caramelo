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
dependencies, scans with Brakeman, runs Rails tests, and verifies test seeds.
Run the browser suite separately:

```sh
bin/rails test:system
```

Individual commands are available when working on a focused change:

```sh
bin/rails test
bin/rubocop
bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
bin/bundler-audit
bin/importmap audit
```

GitHub Actions runs lint, Ruby and JavaScript security scans, unit tests, and
system tests for pull requests and pushes to `main`.

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
bin/rails test:system
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
