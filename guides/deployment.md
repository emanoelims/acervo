# Production deployment

Acervo runs at [acervo.fly.dev](https://acervo.fly.dev) in the Fly `personal`
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

The unmanaged Postgres app `sisteo-apps-db` hosts a separate `acervo` database
and a non-superuser `acervo` role. The app connects over Fly's private IPv6
network (`ECTO_IPV6=true`). Sisteo's schema is never modified.

The first migration runs `CREATE EXTENSION` for `citext`, `unaccent` and
`vector` (pgvector). The role must be allowed to create them: either the
extension is marked trusted (`citext` and `unaccent` are in stock Postgres;
check pgvector's control file on the server), or an administrator creates the
extension in the `acervo` database beforehand, which makes the migration's
`IF NOT EXISTS` a no-op. When bootstrapping with `--superuser=false`, also grant
the role `CREATE` on its own database:

```sql
GRANT CREATE ON DATABASE acervo TO acervo;
```

Do not grant cluster-wide privileges or run schema migrations manually in the
SQL console. The server image must ship the pgvector extension files.

## Secrets

Fly secrets (the app refuses to boot in production without them):

- `DATABASE_URL`: assigned by the database attachment.
- `SECRET_KEY_BASE`: a separate randomly generated application secret.
- `ANTHROPIC_API_KEY`: the Claude API credential.
- `ACERVO_ALLOWED_EMAILS`: comma-separated allowlist for magic-link sign-in.
- `RESEND_API_KEY`: the authorized Resend credential.
- `MAIL_FROM`: the verified sender email address only, without a display name.

GitHub's encrypted `FLY_API_TOKEN` secret contains an app-scoped deployment token
for `acervo`, initially valid for one year. Rotate it before expiry with
`fly tokens create deploy --app acervo --expiry 8760h` and replace the GitHub
secret. Never paste its output into logs, release notes, or source files. Stage
Fly secrets with `fly secrets import --stage` to preserve the release-only
deployment policy.

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
