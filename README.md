# LocalFolio

LocalFolio is a local-first portfolio tracker. It currently provides the
single-user application foundation; portfolio data, calculations, and market
integrations will arrive in later milestones.

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
and transaction placeholder are available without signing in. User, session,
password hashing, and password-reset foundations are present for future use.

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
location you choose. No external database, cache, queue, market-data provider,
or authentication service is required.

The interface is English, the application time zone is
`America/Sao_Paulo`, and future portfolio reporting defaults to Brazilian real
(`BRL`). Currency conversion is outside the current Foundation scope.

## Development

For native Ruby setup, tests, security checks, contribution conventions, and
the complete Foundation acceptance commands, see [DEVELOPMENT.md](DEVELOPMENT.md).
