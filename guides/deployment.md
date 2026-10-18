# Production deployment

Acervo runs at [acervo-app.fly.dev](https://acervo-app.fly.dev) in the Fly `personal`
organization, region `gru`. The app uses one shared CPU and 1 GB of memory, and
one machine stays running. Provisioning (app, database, secrets, token) is done
once by hand; nothing deploys until a release is published.

## Publishing

Production deploys only when a **stable GitHub release is published**. Pushing
to `main`, pushing a tag, saving a release draft, and publishing a prerelease
do not deploy. The release workflow reruns the shared CI checks before deploying
the tagged commit, and rejects commits outside `main`. Deploys are serialized.

1. Update `mix.exs` and this release's entry in `CHANGELOG.md`.
2. Run `mise run precommit`.
3. Merge to `main` and wait for `Conventions` and `Elixir checks` to pass.
4. Tag that commit as `vX.Y.Z`; the tag must match `mix.exs`.
5. Publish the GitHub release for that tag and watch the **Deploy release**
   workflow.
6. Confirm the `/health` check passes and open the login screen.

The workflow builds the Docker image remotely, runs `/app/bin/migrate` in a
temporary release machine, and waits for the database-backed `/health` check. A
failed migration blocks the rollout. Migrations are not automatically rolled
back if deployment fails; schema changes must stay compatible with the previous
release during rollout. Redeploy an earlier compatible image through the Fly
dashboard for emergency recovery, accounting for any applied migrations.

## Database

Acervo shares the unmanaged Fly Postgres app `sisteo-apps-db` (region `gru`,
Postgres 18) with sisteo and leitor. Acervo has its own `acervo` database and a
non-superuser `acervo` role; the other schemas are never modified. The app
connects over Fly's private IPv6 network (`ECTO_IPV6=true`). The volume was
extended to 10 GB because acervo stores images in the database.

### Custom image with pgvector

The stock `flyio/postgres-flex` image has no pgvector. The cluster runs a custom
image, defined in `infra/sisteo-apps-db/Dockerfile`: `flyio/postgres-flex:18.1`
pinned by digest, plus the PGDG package `postgresql-18-pgvector=0.8.6-1.pgdg24.04+1`.
It is published as `registry.fly.io/sisteo-apps-db:pgvector-0.8.6`.

Build and push it from that directory (its `fly.toml` only holds
`app = "sisteo-apps-db"`):

```sh
cd infra/sisteo-apps-db
fly deploy --build-only --push -a sisteo-apps-db --image-label pgvector-0.8.6 --remote-only
```

Applying it restarts the shared database for about a minute, which affects
sisteo and leitor. Take a volume snapshot first, then update the machine:

```sh
fly volumes snapshots create <vol> -a sisteo-apps-db
fly machine update <id> -a sisteo-apps-db --image registry.fly.io/sisteo-apps-db:pgvector-0.8.6
```

Upgrading postgres-flex (a new base tag or digest, or a new major version)
means rebuilding this image with the new base and pgvector package.

### Database and role

Created on 2026-10-18 by attaching the app:

```sh
fly postgres attach sisteo-apps-db --app acervo-app --database-name acervo --database-user acervo --superuser=false
```

### Extensions

`vector` is not a trusted extension, so the `acervo` role cannot create it. The
cluster superuser `flypgadmin` (its password is the machine's `SU_PASSWORD`
environment variable, on the direct Postgres port 5433) created the extensions
and granted the role the rights it needs:

```sh
fly ssh console -a sisteo-apps-db -C "sh -c 'PGPASSWORD=\$SU_PASSWORD psql -h localhost -p 5433 -U flypgadmin -d acervo -c \"CREATE EXTENSION IF NOT EXISTS citext; CREATE EXTENSION IF NOT EXISTS unaccent; CREATE EXTENSION IF NOT EXISTS vector;\"'"
fly ssh console -a sisteo-apps-db -C "sh -c 'PGPASSWORD=\$SU_PASSWORD psql -h localhost -p 5433 -U flypgadmin -d acervo -c \"GRANT CREATE ON DATABASE acervo TO acervo; GRANT CREATE ON SCHEMA public TO acervo;\"'"
```

The backslash makes the remote shell expand `$SU_PASSWORD`, so the password never touches your machine. The app's
migrations then find the extensions already present (`IF NOT EXISTS`). Do not
grant cluster-wide privileges or run schema migrations by hand.

## Secrets

Secrets on `acervo-app` (the app refuses to boot in production without them),
all staged with `fly secrets set --stage` to preserve the release-only
deployment policy:

- `DATABASE_URL`: set by the database attachment above.
- `SECRET_KEY_BASE`: newly generated, separate from every other app.
- `ANTHROPIC_API_KEY`, `RESEND_API_KEY` and `MAIL_FROM`: reuse leitor's values,
  copied machine to machine without printing them, for example
  `fly ssh console -a leitor -C 'printenv RESEND_API_KEY'` piped into
  `fly secrets set --stage --app acervo-app RESEND_API_KEY=...` (read from
  stdin or a variable, never echoed). `MAIL_FROM` is the verified sender address
  only, without a display name.
- `ACERVO_ALLOWED_EMAILS`: the owner's address (comma-separated allowlist for
  magic-link sign-in).

The GitHub encrypted secret `FLY_API_TOKEN` is a deploy token for `acervo-app`,
valid for one year: `fly tokens create deploy --app acervo-app --expiry 8760h`.
Rotate it before expiry and replace the GitHub secret. Never paste its output
into logs, release notes, or source files.

Non-secret settings live in `fly.toml` (`PHX_HOST`, `PORT`, `POOL_SIZE`,
`ECTO_IPV6`, `DNS_CLUSTER_QUERY`).

## Image and health check

The Docker context excludes personal mise overrides, `.env` files, `.sprite`,
temporary files, and Git metadata. Assets are built in the image: a Node stage
installs `assets/package-lock.json` with `npm ci --ignore-scripts`, and
`mix assets.deploy` runs without a second install.

The public `/health` route has no pipeline and no browser session, because Fly's
check sends no cookies or CSRF token. It runs `SELECT 1` and reports only
`{"status":"ok"}` (200) or `{"status":"unavailable"}` (503). Never enable
development routes on Fly.

## One-off tasks

Release tasks run inside the app's machine with `bin/acervo eval`. They start
only what they need, so they are safe next to the running server.

### Reader content backfill

Links captured before reader mode have no article. Enqueue one
`Acervo.Library.ExtractContent` job per ready web-page link that was never
extracted:

```sh
fly ssh console -a acervo-app -C "/app/bin/acervo eval 'Acervo.Release.backfill_reader_content()'"
```

It prints how many links were enqueued. The running app's `content` queue
fetches each page again, one at a time, and stores only its article and the
article's images; titles, notes, collections and preview images are untouched.
Rerunning it skips links already extracted, and rerunning a job replaces that
link's previous article images. Watch progress in the logs or with
`SELECT count(*) FROM links WHERE content_extracted_at IS NULL AND source = 'generic'`.
