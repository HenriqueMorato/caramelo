# Repository Guidelines

## Project Structure & Module Organization

LocalFolio is a Rails 8.1 application. Code follows standard Rails
paths under `app/`. Put workflows or calculations in services when model
methods no longer express them clearly. Tests mirror the application under
`test/`, with records in `test/fixtures`. See `DEVELOPMENT.md` for environment
and Docker setup.

## Build, Test, and Development Commands

- `bin/setup --skip-server`: install gems and prepare the development database.
- `bin/rails db:seed`: idempotently create the configured owner.
- `bin/dev`: run Rails and Tailwind on port 3000.
- `bin/rails test`: run non-system Minitest tests.
- `bin/rails test test/models/user_test.rb:10`: run one test line.
- `bin/rails test -i /owner/`: run tests matching a name.
- `bin/rails test:system`: iterate on Selenium/Chrome system tests.
- `bin/ci`: run setup, lint, security, tests, system tests, and seeds.
- `docker build -t local_folio .`: verify the production image.

Prefer binstubs over `bundle exec`.

## Coding Style & Architecture

Use two-space Ruby indentation, `CamelCase` classes, `snake_case` methods/files,
and RuboCop’s Rails Omakase rules. Keep controllers thin, use strong parameters,
and enforce invariants server-side. Comments explain why, not what. Avoid N+1
queries with `includes` or `preload`. Make migrations additive and reversible;
add deliberate foreign keys, indexes, null constraints, and uniqueness
constraints.

Store money as integer subunits plus an ISO currency. Use precise decimals for
quantities and FX rates; never persist financial values as floats.

## Testing Guidelines

Name Minitest files `*_test.rb`. Add model tests for invariants, request tests for
public behavior, and system coverage for UI flows. Reuse
fixtures and cover currencies and boundary cases. Run focused tests while
iterating, then `bin/ci` before proposing a commit.

## Project Guardrails

Scope owner data through `User.owner`; never trust a request-supplied user ID.
The application remains public and single-user until login is activated.
Preserve local-first SQLite operation. User-entered financial records are
durable; market quotes are replaceable cache data unless explicitly
modeled as daily history.

## Commits, Pull Requests & Security

Use issue-prefixed branches such as `feat/19-money-foundation` and Conventional
Commit/PR titles. Keep commits focused, include `Closes #<issue>` in PR bodies,
record verification, attach screenshots for UI changes, and merge only with
green checks. Never commit `.env*`, keys, credentials, or SQLite data.

Agents must obtain fresh one-time user approval before creating or rewriting a
commit or merge. Approval applies only to the exact staged state and message and
must be requested again after any index change.
