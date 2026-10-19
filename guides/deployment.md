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

### Search sizes

What search adds, for the shared cluster and the 1 GB app machine:

- **Per link:** a `vector(1024)` is 4,104 bytes, stored out of line in TOAST.
- **HNSW index** (`links_embedding_index`): each element takes about one 8 KB
  page, so about 8 MB per 1,000 links (80 MB at 10,000). `search_tsv` and its
  GIN index add well under 1 MB per 1,000 links.
- **Build:** the migration built the index while every embedding was NULL, so
  it was instant; later embeddings update the graph one at a time.
  `maintenance_work_mem` only matters for a rebuild past about 8,000 links.
- **App:** the query cache holds at most 500 vectors (about 2 MB), and a
  search holds about 40 KB at a time for its vector list.
- **Later:** `halfvec(1024)` would halve all of this if it ever matters.

Check the real numbers with
`SELECT pg_size_pretty(pg_relation_size('links_embedding_index')), pg_size_pretty(pg_total_relation_size('links'))`.

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
- `ACERVO_CHAT_MODEL` (optional): the Claude model that enriches links, such as
  `anthropic:claude-haiku-5-5` to spend less. Without it, Opus 5.5
  (`anthropic:claude-opus-5-5`) is used.
- `ACERVO_ALLOWED_EMAILS`: the owner's address (comma-separated allowlist for
  magic-link sign-in).
- `OPENROUTER_API_KEY`: the OpenRouter key for search embeddings (required
  since 0.9.0). Search falls back to matching words only while it is missing or
  OpenRouter is down, and links are not embedded.
- `ACERVO_EMBEDDING_MODEL` (optional): the embedding model, by default
  `openrouter:voyageai/voyage-4-lite`. It must return 1024-dimension vectors,
  or the `links.embedding` column and its migration must change. See
  "Changing the embedding model" below.
- `ACERVO_SHOTS_URL` and `ACERVO_SHOTS_TOKEN` (optional): the screenshot
  service's URL and its bearer token, set up as in
  [`infra/screenshots/README.md`](../infra/screenshots/README.md). With both,
  links without a preview image get a screenshot of their first screen and
  the link column can generate a new one; without them that feature is off.
  Generate the token with `openssl rand -hex 32`, set the same value on the
  Sprite, and stage it from stdin or a variable, never echoed.

The GitHub encrypted secret `FLY_API_TOKEN` is a deploy token for `acervo-app`,
valid for one year: `fly tokens create deploy --app acervo-app --expiry 8760h`.
Rotate it before expiry and replace the GitHub secret. Never paste its output
into logs, release notes, or source files.

Non-secret settings live in `fly.toml` (`PHX_HOST`, `PORT`, `POOL_SIZE`,
`ECTO_IPV6`, `DNS_CLUSTER_QUERY`). `METRICS_PORT` is optional (9568 by
default); if it changes, change `[metrics]` in `fly.toml` with it.

## Image and health check

The Docker context excludes personal mise overrides, `.env` files, `.sprite`,
temporary files, and Git metadata. Assets are built in the image: a Node stage
installs `assets/package-lock.json` with `npm ci --ignore-scripts`, and
`mix assets.deploy` runs without a second install.

The public `/health` route has no pipeline and no browser session, because Fly's
check sends no cookies or CSRF token. It runs `SELECT 1` and reports only
`{"status":"ok"}` (200) or `{"status":"unavailable"}` (503). Never enable
development routes on Fly.

## Metrics

The app exports Prometheus metrics at `/metrics` on port 9568
(`METRICS_PORT`), declared under `[metrics]` in `fly.toml`. Fly scrapes it
every 15 seconds over its private network; the port is not in
`http_service`, so it is not public. In development it listens on
`localhost:9568` while `mix phx.server` runs: `curl -s localhost:9568/metrics`.
Tests, mix tasks and `bin/acervo eval` don't start it.

What is exported (`AcervoWeb.Metrics`):

- **AI:** `acervo_ai_calls_total` by operation, model and status; input and
  output tokens; the estimated cost as `acervo_ai_cost_nanousd_total`
  (billionths of a dollar, so divide by `1e9`); latency as a histogram.
  `ai_calls` stays the exact record (see "AI costs" below).
- **Search:** latency histogram, `acervo_search_total` by `partial`,
  `cached` and `scoped`, and the results returned.
- **Background jobs:** Oban jobs by queue, worker and state, their duration and
  time in queue, and queue depth (available, scheduled, retryable, executing)
  every 30 seconds.
- **Links:** totals by `status`, `enrichment_status` and `embedding_status`,
  every 30 seconds.
- **Standard:** Phoenix request and route duration, LiveView mount and event
  duration, Ecto query time, and VM memory, run queues and process count.

Counters restart from zero on every deploy; query them with `increase()` or
`rate()`, never their raw value.

### Dashboard

Open [fly-metrics.net](https://fly-metrics.net) (or **Metrics** in the Fly
dashboard) and pick the `personal` organization. To add Acervo's dashboard, go
to **Dashboards → New → Import**, upload `infra/grafana/acervo.json` and choose
the **Prometheus on Fly** data source. It shows the AI cost per day and over
the selected range, calls and latency by operation, search latency, partial
and cache hit rates, jobs by state, queue depth, links by status, and VM memory
against the 1 GB limit, all filtered to `app="acervo-app"`. Import it again,
overwriting, after it changes in the repository.

### Labels never carry user data

Fly adds `app`, `region`, `host` and `instance`. The app's own labels come only
from bounded sets: operation, model, status, queue, worker, state, route (the
route pattern such as `/links/:id`, never the path), and the
`partial`/`cached`/`scoped` flags. Never add a label holding a user id, a
query, a URL, a title or an error message: each value creates a new series in
Fly's Prometheus and would publish that data to anyone with metrics access.
`AcervoWeb.MetricsTest` fails when a metric uses a tag outside the allowlist.

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

### Enrichment backfill

Links saved before enrichment have no image description, language or
suggestions. Run the reader content backfill above first and let the `content`
queue finish (the SQL check above shows when it is empty), so the model reads
each article. Then enqueue one `Acervo.AI.EnrichLink` job per ready link that
was never enriched or whose enrichment failed, newest first:

```sh
fly ssh console -a acervo-app -C "/app/bin/acervo eval 'Acervo.Release.backfill_enrichment()'"
```

It prints how many links were enqueued. Each link costs one model call, made by
the running app's `ai` queue, two at a time; a rate limit delays the job and a
failure retries up to three times before the link is marked failed. Every link
gets its image description and language; only links still in the inbox get
collection suggestions. Rerunning it enqueues only links that are still missing
enrichment. Watch progress with
`SELECT enrichment_status, count(*) FROM links GROUP BY 1`.

### Snapshot backfill

Once the screenshot service is set up (see Secrets above), enqueue one
`Acervo.Library.CaptureSnapshot` job per ready web-page link with no card
image (no preview, screenshot or snapshot), newest first, at the lowest
priority:

```sh
fly ssh console -a acervo-app -C "/app/bin/acervo eval 'Acervo.Release.backfill_snapshots()'"
```

It prints how many links were enqueued, and does nothing while the service is
off. The running app's `snapshot` queue takes one screenshot at a time; a busy
service delays the job, and a page that fails is left without an image. A link
never enriched is enriched once its snapshot ends; enriched links keep their
enrichment. Rerunning it skips links that already have an image.

### Search reindex

Every link is embedded for search by `Acervo.Search.EmbedLink`. After deploying
0.9.0, and after changing the embedding model, enqueue one job per ready link
whose embedding is missing or was made with another model than the configured
one, newest first:

```sh
fly ssh console -a acervo-app -C "/app/bin/acervo eval 'Acervo.Release.reindex()'"
```

It prints how many links were enqueued and marks them `pending`; the running
app's `embed` queue works through them, four at a time. Each costs one
embedding call (about $0.00004 for a long article at most). Links already
`pending` are left to their job, so rerunning it is safe. Watch progress with
`SELECT embedding_status, count(*) FROM links GROUP BY 1`: a link with nothing
to embed (no title, text, image description or note) goes back to empty, and a
link whose embedding keeps failing ends as `failed`.

`Acervo.Release.reindex(all: true)` enqueues every ready link instead, for a
change in what is embedded (`Acervo.Search.Document`). Each job compares the
document's digest with the stored one, so a link whose text and model are
unchanged costs no call. In development, with the server running, use
`mise exec -- mix acervo.reindex` (or `--all`); the server's queue does the
work.

### Changing the embedding model

1. Stage the new model: `fly secrets set --stage --app acervo-app ACERVO_EMBEDDING_MODEL=...`.
   It must return 1024 dimensions.
2. Deploy, then run the search reindex above.

Search compares a query only with vectors from the configured model, so while
the reindex runs, text search keeps working and the vector side finds only the
links already embedded with the new model.

### AI costs

Every model call, embeddings included, is recorded in `ai_calls` with its
tokens and an estimated cost (`Acervo.AI.Rates`, at Anthropic's and
OpenRouter's published prices). Print the last 30 days per day, or pass another
number of days:

```sh
fly ssh console -a acervo-app -C "/app/bin/acervo eval 'Acervo.Release.ai_costs()'"
```

The same numbers in SQL:

```sql
SELECT inserted_at::date AS day, count(*) AS calls,
       sum(input_tokens) AS tokens_in, sum(output_tokens) AS tokens_out,
       sum(cost_usd) AS usd
FROM ai_calls
WHERE inserted_at > now() - interval '30 days'
GROUP BY 1 ORDER BY 1;
```
