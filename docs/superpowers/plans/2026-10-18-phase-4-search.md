# Phase 4 — Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Describe a link in free text and find it, including by what its image shows (the phase 3 `image_description`). Every link gets:
- a 1024-dimension embedding of its text, made by `openrouter:voyageai/voyage-4-lite` and refreshed whenever that text changes;
- a generated `search_tsv` for full-text search.

A dock search pill queries both and merges them with Reciprocal Rank Fusion. When embedding the query fails, it falls back to text-only results flagged `partial`. Shipped as `0.9.0` (issue #43).

**Architecture:**
- **`Acervo.AI`:** gains the `Acervo.AI.Embedder` behaviour, implemented by `Acervo.AI.OpenRouterEmbedder` with `ReqLLM.embed/3`. `Acervo.AI.embed/4` records every call in the existing `ai_calls` table, with operation `embed_link` or `embed_query`. Tests use `Acervo.FakeEmbedder`.
- **`Acervo.Search`:**
  - `Acervo.Search.Document` builds the text to embed.
  - `Acervo.Search.EmbedLink` is the Oban worker on the existing `embed` queue.
  - `Acervo.Search.search/3` runs the hybrid query.
  - `Acervo.Search.QueryCache` keeps query vectors briefly in ETS.
- **`Acervo.Library` and `Acervo.Collections`:** enqueue `EmbedLink` inside the transactions that change what is embedded.
- **`AcervoWeb.ArchiveLive`:** gains the `/search` routes, the dock's search item, the search pill and a results column made of the existing cards.

**Tech Stack:** Phoenix 1.8 / LiveView 1.2.12, Ecto + Postgres 18.
- **pgvector:** 0.8.7 in dev and 0.8.6 in prod, so `hnsw.iterative_scan` is available. The Elixir package `pgvector` 0.4.2 is already a dependency, and `Acervo.PostgrexTypes` is already wired.
- **Oban:** 2.24.1, Basic engine.
- **ReqLLM:** 1.28.0, with `llm_db` 2026.10.2.

No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-18-acervo-design.md`. Read the Decisions (Embeddings), Data model (`embedding`, `embedding_model`, `search_tsv`), AI enrichment → `EmbedLink`, Search, Interface → Dock, Configuration, Testing and Risks sections. **Reference:** phase 3's `lib/acervo/ai/enrich_link.ex` (enqueue, uniqueness, error classes, snooze, crash logging), `lib/acervo/ai/claude.ex` (error mapping, no retries, usage) and `test/support/fake_ai_client.ex` (the stub through `$callers`).

## What the deps say (verified 2026-10-18)

- **`ReqLLM.embed/3`** (`deps/req_llm/lib/req_llm/embedding.ex`, delegated from `ReqLLM`):
  - It takes a string or a list of strings.
  - Options: `dimensions`, `encoding_format`, `provider_options`, `req_http_options`, `total_timeout` (a deadline that includes retries), `return_usage`, plus the provider and generation options (`api_key`, `receive_timeout`, `max_retries`).
  - With `return_usage: true` it returns `{:ok, %{embedding: [float], usage: map}}`.
  - When `dimensions` is given, it checks the vector length itself and returns an `%ReqLLM.Error.API.Response{reason: "Embedding dimension mismatch…"}` on mismatch.
  - A non-2xx response becomes `%ReqLLM.Error.API.Request{status:, response_body:}`. **The body is in the error**, so it must never be logged.
- **OpenRouter provider** (`providers/openrouter.ex`):
  - Embeddings use the default OpenAI-compatible `POST /embeddings`.
  - `dimensions`, `encoding_format` and `input_type` go into the body (top level or in `provider_options`). The `input_type` doc says "such as search_query or search_document"; Voyage itself uses `query` and `document`.
  - The key comes from `api_key:`, or `OPENROUTER_API_KEY` by default.
  - `default_attach` adds ReqLLM's retry step (3 retries by default), so pass `max_retries: 0` as phase 3 did.
- **Usage and cost:**
  - `ReqLLM.Step.Usage` marks embedding output as reported (0 output tokens).
  - `total_cost` comes from LLMDB pricing through `ReqLLM.Billing.calculate/3`. For `voyage-4-lite`, `pricing` is `null` but `cost.input` is 0.02, so whether `total_cost` is filled is **unknown until the spike**.
  - OpenRouter's own `usage.cost` in the body is not read by ReqLLM.
- **`llm_db` 2026.10.2:** `openrouter` → `voyageai/voyage-4-lite` **exists**.
  - `capabilities.embeddings: true` (a bare boolean, with **no** `min_dimensions`/`max_dimensions`/`default_dimensions`), `execution.embed.family: "openai_embeddings"`, context 32,000 tokens, `cost: %{input: 0.02, output: 0.0}` USD per million tokens, released 2026-07-27.
  - LLMDB therefore cannot confirm that `dimensions` is honored. Voyage 4 models natively default to 1024 dimensions and accept 256, 512, 1024 and 2048 (`output_dimension`), but whether OpenRouter forwards `dimensions` is unverified. **Task 1's spike decides; see Open question 1.**
  - Embedding models on OpenRouter with a confirmed 1024 option: `mistralai/mistral-embed-2312` (fixed 1024, $0.10/M), `mistralai/codestral-embed-2505` (fixed 1024, code-oriented), and `openai/text-embedding-3-small` / `-large` (1..1536 / 1..3072, $0.02 / $0.13 per M).
- **Oban 2.24.1 Basic engine:** `insert_all` **ignores `unique`** (see the tip in `Oban.insert_all/3`). Bulk enqueues must loop over `Oban.insert/2` inside one transaction.
- **LiveView 1.2.12 `start_async/3`:** "If there is an in-flight task with the same name, the later `start_async` wins and the previous task's result is ignored." Stale search results are dropped for free.
- **Postgres 18:** a generated column is **`VIRTUAL` by default**, and virtual generated columns cannot be indexed. `search_tsv` must say `STORED` explicitly.
- **Cachex is not a dependency.** The query cache is a small ETS table (see Task 4).
- **Shortcuts in use** (`.Shortcuts` in `archive_live.ex`, `.SubmitShortcut` and `.ScreenshotPaste` in `link_components.ex`, `assets/js/floating.js`): ⌘/Ctrl V, ↩, Esc, ⌘/Ctrl ↩, `?`, plus typeahead letters and arrows inside open menus. **`/` and ⌘/Ctrl K are free.**
- **Icons:** only 55 Lucide SVGs are vendored in `assets/vendor/lucide/`. `search.svg` and a "partial" icon must be added (Task 5).

## Global Constraints

Everything from phases 2 and 3 still applies:
- Conventional Commits PRs, squash-merged with `gh pr merge --squash --admin --delete-branch` after `Conventions` and `Elixir checks` pass.
- `mise run precommit` before every commit.
- The 7-day rule for dependencies (none are added here).
- `use Acervo.Schema`, and `%Scope{}` first on every context function.
- Minimal UI copy with icons, tooltips and DOM ids. English msgids, with pt_BR filled in.
- `Req.Test` stubs and no network in tests. CHANGELOG `[Unreleased]`, new env vars in `mise.local.toml.example`.
- Chrome checks for UI work. The dev server runs on `:4200`; Postgres runs in the `acervo-db` container.
- Keep `/guide` and `guides/features.md` in step.

Search-specific rules for every task:
- **No content in logs.** Log link ids, the model, token counts, cost, duration, result counts, `partial`, `cached`, and the error class or HTTP status only. Never log the query text, the document text, a vector, or a ReqLLM error struct (its `response_body` may echo input). Keep ReqLLM telemetry at the default (metadata only).
- **No string-built SQL.** Every user value reaches Postgres as a bound parameter (`^value` or `$n`). The only raw statements are the constant `SET LOCAL` lines in Task 4. A review checkpoint greps for this.
- **Strip NUL** (`<<0>>`) and C0/C1 control characters from the query and the document. Postgres `text` rejects NUL.
- **Embedding calls cost money, a little.** voyage-4-lite costs $0.02 per million input tokens, so a 2,000-token link costs about $0.00004. The only real calls happen in Task 1's spike and Task 6's verification, never in a test or a loop.
- **No network in tests.** `config :acervo, :embedder, Acervo.FakeEmbedder` everywhere except the adapter's own tests. Those run real ReqLLM code against `Req.Test` with `req_http_options: [plug: {Req.Test, Acervo.AI.OpenRouterEmbedder}]`.
- **Lock order: the link row first.** Every transaction that touches a link and its suggestions or memberships locks the `links` row (`FOR NO KEY UPDATE`) **before** suggestion or `collection_links` rows. `finish_triage/2` and `replace_suggestions/3` already do. A `FOR NO KEY UPDATE` lock still lets foreign-key checks (`KEY SHARE`) through, so inserts that reference the link do not block on it.
- **Vectors from different models never mix.** The vector query only considers rows whose `embedding_model` equals the configured model.

## Task overview

| # | Task | Model | Depends on |
|---|------|-------|------------|
| 1 | Embedder client, cost records, fake embedder, spike | Opus | — |
| 2 | Search schema: embedding columns, `search_tsv`, indexes | Sonnet | — |
| 3 | `EmbedLink`: document, worker, enqueue points, reaper | Opus | 1, 2 |
| 4 | Hybrid search context, query cache, reindex | Opus (reindex steps Sonnet-grade) | 1, 2; reindex step needs 3 |
| 5 | Search UI: dock pill, `/search` routes, results column, guides | Opus | 4 |
| 6 | Release 0.9.0, real-data verification, production reindex | controller | 1–5 |

Tasks 1 and 2 can run in parallel. Task 4's query work can start once 1 and 2 are merged; its reindex step waits for 3.

## File map

| File | Task | Change |
|---|---|---|
| `lib/acervo/ai/embedder.ex` | 1 | new behaviour |
| `lib/acervo/ai/open_router_embedder.ex` | 1 | new, ReqLLM adapter |
| `lib/acervo/ai.ex` | 1 | `embedding_model/0`, `embedding_dimensions/0`, `embed/4` |
| `lib/acervo/ai/client.ex` | 1 | move `classify/1` here from `EnrichLink` (shared) |
| `lib/acervo/ai/rates.ex` | 1 | embedding rate, only if the spike shows `total_cost` is nil |
| `lib/acervo/ai/enrich_link.ex` | 1, 3 | use `Client.classify/1`; enqueue `EmbedLink` at terminal outcomes |
| `config/config.exs`, `config/runtime.exs`, `config/test.exs`, `mise.local.toml.example` | 1, 4 | embedder, model, key, search timeout |
| `test/support/fake_embedder.ex` | 1 | new |
| `priv/repo/migrations/*_add_search_to_links.exs` | 2 | new |
| `lib/acervo/library/link.ex` | 2 | embedding fields |
| `lib/acervo/search/document.ex` | 3 | new |
| `lib/acervo/search/embed_link.ex` | 3 | new worker |
| `lib/acervo/library.ex` | 3, 4 | enqueue on note and image description edits; `list_links_by_ids/2` |
| `lib/acervo/collections.ex` | 3 | enqueue on membership change, rename and delete; lock order |
| `lib/acervo/library/capture_link.ex`, `lib/acervo/library/extract_content.ex` | 3 | enqueue when enrichment is not enqueued |
| `lib/acervo/library/reap_stuck_captures.ex` | 3 | third pass for embeddings |
| `lib/acervo/search.ex` | 4 | new context |
| `lib/acervo/search/query_cache.ex` | 4 | new ETS cache |
| `lib/acervo/application.ex` | 4 | `Acervo.TaskSupervisor`, `Acervo.Search.QueryCache` |
| `lib/acervo/release.ex`, `lib/mix/tasks/acervo.reindex.ex` | 4 | `reindex/1`, `stale_embeddings/2`, mix task |
| `guides/deployment.md` | 4 | secrets, reindex, model change, sizes |
| `lib/acervo_web/router.ex` | 5 | `/search`, `/search/l/:id`, `/search/l/:id/web` |
| `lib/acervo_web/live/archive_live.ex` | 5 | search filter, events, async, `.Shortcuts` keys |
| `lib/acervo_web/components/archive_components.ex` | 5 | dock search item, `search_pill/1` |
| `lib/acervo_web/components/guide_components.ex`, `guides/features.md` | 5 | Search section and shortcuts |
| `assets/css/archive.css` | 5 | pill scope chip, partial icon |
| `assets/vendor/lucide/{search,zap-off}.svg`, `README.md` | 5 | icons |
| `priv/gettext/**`, `CHANGELOG.md` | 3–5 | copy |
| `mix.exs`, `CHANGELOG.md`, the spec | 6 | release |

---

### Task 1: Embedder client, cost records, fake embedder, spike  *(Opus)*

**Files:**
- Create: `lib/acervo/ai/embedder.ex`, `lib/acervo/ai/open_router_embedder.ex`, `test/support/fake_embedder.ex`, `test/support/fixtures/ai/embedding.json`
- Modify: `lib/acervo/ai.ex`, `lib/acervo/ai/client.ex`, `lib/acervo/ai/enrich_link.ex` (use the shared `classify/1`), `lib/acervo/ai/rates.ex` (only if needed), `config/config.exs`, `config/runtime.exs`, `config/test.exs`, `mise.local.toml.example`
- Test: `test/acervo/ai/open_router_embedder_test.exs`, additions to `test/acervo/ai_test.exs`

**Interfaces:**
- **Config:**
  - `config/config.exs`: `config :acervo, :embedder, Acervo.AI.OpenRouterEmbedder`.
  - `config/runtime.exs`:
    - `config :acervo, :embeddings, model: System.get_env("ACERVO_EMBEDDING_MODEL", "openrouter:voyageai/voyage-4-lite")`
    - `config :acervo, :openrouter, api_key: System.get_env("OPENROUTER_API_KEY")`
    - In the prod block, raise when `OPENROUTER_API_KEY` is missing, like `ANTHROPIC_API_KEY`. The spec marks it required, and it is already staged.
  - `config/test.exs`: `config :acervo, :embedder, Acervo.FakeEmbedder` and `config :acervo, :embed_req_options, plug: {Req.Test, Acervo.AI.OpenRouterEmbedder}`.
  - `mise.local.toml.example`: `OPENROUTER_API_KEY = ""` and `# ACERVO_EMBEDDING_MODEL = "openrouter:voyageai/voyage-4-lite"` with a one-line comment saying the model must return 1024 dimensions.
- **`Acervo.AI.Embedder`** (behaviour):
  - `@callback embed(model :: String.t(), text :: String.t(), opts :: keyword()) :: {:ok, [float()]} | {:error, Acervo.AI.Client.error()}`
  - `opts`:
    - `:dimensions` (always 1024 from `Acervo.AI`);
    - `:input_type` (`:document | :query`);
    - `:receive_timeout`;
    - `:usage_callback`, called once per completed HTTP response, including one whose vector is rejected.
- **`Acervo.AI.OpenRouterEmbedder`:** mirror `Acervo.AI.Claude`.
  - **Missing key:** `api_key` comes from `Application.get_env(:acervo, :openrouter)[:api_key]`. If it is nil or `""`, return `{:error, :unavailable}` with no request.
  - **Model:** `ReqLLM.Embedding.validate_model/1`. On error, return `{:error, :provider_error}`.
  - **Call:** `ReqLLM.embed(model, text, ...)` with:
    - `api_key:`, `dimensions:` and `return_usage: true`;
    - `provider_options: [input_type: ...]` (`"document"`/`"query"`, or nothing, per the spike);
    - `receive_timeout:` (default 15 s) and `max_retries: 0`;
    - `req_http_options: [retry: false] ++ Application.get_env(:acervo, :embed_req_options, [])`.
  - **Success:** call the usage callback with `Acervo.AI.Claude.usage/1`-style filtering (`input_tokens`, `output_tokens`, `total_cost`; the embedding usage map's keys may be `:input`/`:output`, so map both). Return `{:ok, vector}` only when it is a list of numbers of length `opts[:dimensions]`; otherwise `{:error, :invalid_response}`.
  - **Errors:** reuse `Acervo.AI.Claude.map_error/1` (make it the shared `Acervo.AI.Client.map_error/1`). A dimension-mismatch `API.Response` maps to `:invalid_response`. Log only the module, status and error code.
- **`Acervo.AI`:**
  - `@spec embedding_model() :: String.t()`
  - `@spec embedding_dimensions() :: 1024` (a module attribute; the column type fixes it).
  - `@spec embed(Scope.t(), %{operation: String.t(), link_id: Ecto.UUID.t() | nil}, String.t(), keyword()) :: {:ok, [float()]} | {:error, Client.error()}`
    - It shares the private `record/2`, `log/1`, `receive_usage/1` and `cost/2` helpers with `generate_object/4`. Extract a `run_call/4` that both use.
    - It writes one `ai_calls` row per call, with operation `"embed_link"` or `"embed_query"` and `output_tokens` as reported (0 for embeddings, never invented).
    - Accepted opts: `:input_type` and `:receive_timeout`.
- **`Acervo.AI.Client`:** gains `classify/1` (moved verbatim from `EnrichLink`, which now calls it) and `map_error/1` (moved from `Claude`).
- **`Acervo.AI.Rates`:** only if the spike shows `total_cost` nil, add `rates("openrouter:voyageai/voyage-4-lite", _)` → `{Decimal.new("0.02"), Decimal.new("0")}`. Stop stripping the `"anthropic:"` prefix, so every rate is keyed by the full model spec, and update the moduledoc date.
- **`Acervo.FakeEmbedder`** (`test/support`):
  - **Default, with no stub:** a **deterministic** vector. Seed `:rand.seed_s(:exsss, <<n::256>>)` with `sha256(text)`, take 1024 uniform floats in -1..1, and L2-normalize them. The spec's fake "hashes text into deterministic 1024-dimension vectors". Unlike `FakeAIClient` it does not raise: the config already guarantees no network, and LiveView search tests need vectors without stubbing.
  - `stub(fun, opts \\ [])` takes `fun.(model, text, opts)`, found through `$callers` as in `FakeAIClient`.
  - `vector(text)` exposes the default.
  - `axis(i, weight \\ 1.0)` returns a unit vector on dimension `i`. `blend([{i, w}, ...])` returns a normalized mix, so tests design cosine ordering by construction.
  - It reports `%{input_tokens: 12, output_tokens: 0, total_cost: 0.00000024}` through `:usage_callback`.
  - `calls/0` counts calls in the test process, for the cache test.

- [ ] **Step 1:** Branch `feat/embedder`. Use Tidewave `get_docs` on `ReqLLM.embed/3`, `ReqLLM.Embedding` and `ReqLLM.Providers.OpenRouter` to confirm the options above. Offline, check that `ReqLLM.Embedding.validate_model("openrouter:voyageai/voyage-4-lite")` returns `{:ok, _}`.
- [ ] **Step 2 (spike: one real call, dev only, two at most).** With the real key from `mise.local.toml` (never print it), run one `Acervo.AI.embed/4` through Tidewave `project_eval`. Use the owner's scope, `%{operation: "embed_link", link_id: nil}`, the text `"Um cachorro correndo na praia ao pôr do sol"`, `dimensions: 1024` and `input_type: :document`. Record:
  - **Dimensions:** whether OpenRouter accepted `dimensions`, and the vector length. If the call fails with a 400 that names `dimensions` or `input_type`, make **one** more call without that parameter and record which one was rejected. The length must still be 1024 (Voyage's default). If it isn't, stop and raise Open question 1 with the controller.
  - **`input_type`:** accepted or not.
  - **Latency:** the whole call, and the HTTP request time from ReqLLM telemetry (as phase 3 recorded).
  - **Usage:** the map, and whether `total_cost` is filled.
  - **Cost record:** the `ai_calls` row (`cost_usd`, `duration_ms`).

  Never commit the key, the vector or the response. Write the findings under "Spike findings" below, as phase 3 did.
- [ ] **Step 3:** Write the failing tests.
  - **Adapter**, through `Req.Test.stub(Acervo.AI.OpenRouterEmbedder, ...)`, with `Application.put_env(:acervo, :openrouter, api_key: "test-key")` restored in `on_exit`, `async: false`:
    - The fixture `embedding.json` (hand-written in the shape the spike recorded: `data: [%{embedding: [...1024 floats...], index: 0}]` plus `usage`) gives `{:ok, vector}` of length 1024, and the usage callback gets the tokens.
    - The stub asserts the request: `authorization: Bearer test-key`, path `/api/v1/embeddings`, body `model: "voyageai/voyage-4-lite"`, `dimensions: 1024`, and `input_type` when the spike kept it.
    - A 512-float response gives `{:error, :invalid_response}`, and the usage callback still fires.
    - 429 gives `{:rate_limited, _}`, 500 gives `{:http, 500}`, and 400 gives `{:http, 400}`. Exactly one request is made per call.
    - A missing key gives `:unavailable` with no request.
    - `CaptureLog`: no line contains `"test-key"` or the input text.
  - **`Acervo.AI.embed/4`** with the fake: one `ai_calls` row on success (`operation: "embed_query"`, `output_tokens: 0`), and one with `status: :error` on a stubbed `{:error, {:http, 500}}`. `cost_summary/1` includes embedding rows.
  - **Fake:** the same text gives the same vector, and `axis/1` vectors are orthogonal.
  - **`EnrichLink`** still passes its tests with `Client.classify/1`.
- [ ] **Step 4:** Run the tests and confirm they fail. Implement and run `mise run precommit`.
- [ ] **Step 5:** Commit `feat: add the OpenRouter embedder and record the cost of every embedding`, then open the PR, check CI and merge.

**Acceptance:** `mix test` makes no HTTP call. The spike's `ai_calls` row exists. The PR states the confirmed option names, whether `dimensions` and `input_type` were honored, the latency, and where the cost comes from (ReqLLM or `Rates`).

#### Spike findings

Run on 2026-10-18 against the dev server through Tidewave, with the real key: 28 requests and $0.0003 in total. Every call went through `Acervo.AI.embed/4` and is in dev `ai_calls`, except the 512-dimension check, which called `ReqLLM.embed/3` directly.

- **Model:** `openrouter:voyageai/voyage-4-lite` is kept (Decision 1). No fallback to `text-embedding-3-small` was needed.
- **`dimensions`:** honored.
  - `dimensions: 1024` returns 1024 floats with an L2 norm of 1.0.
  - One check with `dimensions: 512` returned 512 floats, so OpenRouter forwards the parameter rather than ignoring it.
- **`input_type`:** accepted and honored.
  - It goes in `provider_options: [input_type: "document" | "query"]`, and the body carries it at the top level.
  - The same text embedded as a query and as a document has a cosine similarity of only 0.744, so the two types really differ.
- **ReqLLM options:** `ReqLLM.embed/3` validates its options strictly.
  - `max_retries` and `receive_timeout` at the top level fail with a `NimbleOptions` error, wrapped in `ReqLLM.Error.Unknown.Unknown`, and no request is made. The first spike attempt failed this way: it is the `provider_error` row in dev `ai_calls`.
  - Both go in `req_http_options` instead. ReqLLM's retry step reads `max_retries` from the Req options, so `[retry: false, max_retries: 0, receive_timeout: ...]` gives exactly one request on a 429 or 500 (checked offline with a plug).
- **Request:** `POST /api/v1/embeddings` with `model: "voyageai/voyage-4-lite"`, `input`, `dimensions`, `encoding_format: "float"` and `input_type`.
- **Latency:**
  - First call: 1.4 s, the same for the whole call and for the HTTP request per `[:req_llm, :request, :stop]` telemetry.
  - Documents afterwards (59 to 2,143 tokens): 0.7 to 2.4 s, median 0.78 s.
  - Queries: 0.68 to 0.99 s, median 0.75 s. That is well inside the 3 s search timeout, with the cache absorbing repeats.
- **Usage:** `%{input_tokens:, output_tokens: 0, total_cost:, ...}` (the `:input`/`:output` aliases are present too). Queries cost 3 to 4 tokens. The 7 dev documents averaged about 1,060 tokens, with a maximum of 2,143.
- **Cost:**
  - `total_cost` is filled but **rounded to $0.000001** (`ReqLLM.Billing` rounds to 6 decimals). A 14-token call reports 0.0, so a short query would record zero and a 25-token one double its cost.
  - So `Acervo.AI.Rates` gained `openrouter:voyageai/voyage-4-lite` at $0.02 per million input tokens, and is now keyed by the full model spec.
  - `Acervo.AI` prefers the dated rate whenever `Rates` knows the model, and falls back to ReqLLM's cost otherwise. Claude is unaffected: ReqLLM never priced it.
  - The spike's `ai_calls` row: `embed_link`, status `ok`, 14 input / 0 output tokens, `cost_usd` 0.00000028, `duration_ms` 1408.
  - Per call: a query is about $0.00000008; a typical document about $0.00002, and $0.00004 at 2,000 tokens.
- **Dimension mismatch:** ReqLLM rejects a wrong length before returning the usage, so the usage callback fires with `%{}` and that call's tokens are lost. This is acceptable, because a mismatch is a configuration error.
- **Similarity cutoff (Decision 2).** 7 dev documents in Task 3's format (the eighth link, an empty Instagram post, would be skipped). Cosine similarity, query type against document type:

  | query | best match | its similarity | highest other |
  |---|---|---|---|
  | machine learning in Elixir | Nx v0.1 post | 0.579 | 0.407 (Elixir v1.17), 0.296 (Req) |
  | github outage | GitHub availability report | 0.588 | 0.186 |
  | música dos anos 80 | Rick Astley video (cross-lingual, implied) | 0.319 | 0.084 |
  | xyzzy plover (nonsense) | — | — | 0.227 (a 59-token tweet) |
  | receita de bolo de chocolate (off-topic) | — | — | 0.123 |

  - Relevant hits score 0.32 to 0.59. Noise stays at or below 0.23, and short documents drift highest.
  - **Proposed cutoff: keep vector hits with similarity ≥ 0.27, that is `max_distance: 0.73` on `<=>`.** It keeps the weakest real match (0.319), drops the noisiest unrelated document (0.227), and passes "Req" for the Elixir ML query (0.296, related).
  - Recheck it in Task 6 with more links, because 7 documents is a thin sample.

---

### Task 2: Search schema — embedding columns, `search_tsv`, indexes  *(Sonnet)*

**Files:**
- Create the migration with `mix ecto.gen.migration add_search_to_links`
- Modify: `lib/acervo/library/link.ex`
- Test: `test/acervo/library/link_test.exs`, new `test/acervo/search/schema_test.exs`

**Migration** (one file; `up`/`down` with `execute` for the raw parts):
- **Columns:**
  - `embedding vector(1024)`: `add :embedding, :vector, size: 1024`.
  - `embedding_model varchar(200)`, `embedding_digest bytea` (SHA-256 of model plus document; see Task 3), `embedding_status varchar` (nullable; nil means never enqueued), `embedded_at timestamp(0)`.
- **`search_tsv`**, **stored** generated. Postgres 18 defaults to `VIRTUAL`, which cannot be indexed. The spec's fields, plus `site_name` and `author` at the lowest weight (see Open question 6):
  ```sql
  ALTER TABLE links ADD COLUMN search_tsv tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('simple'::regconfig, acervo_unaccent(coalesce(title, ''))), 'A') ||
    setweight(to_tsvector('simple'::regconfig, acervo_unaccent(
      coalesce(description, '') || ' ' || coalesce(image_description, '') || ' ' || coalesce(note, ''))), 'B') ||
    setweight(to_tsvector('simple'::regconfig, acervo_unaccent(
      coalesce(site_name, '') || ' ' || coalesce(author, '') || ' ' || coalesce(text_excerpt, ''))), 'C')
  ) STORED
  ```
  - `acervo_unaccent` is `STRICT`, hence the `coalesce`s inside it.
  - Adding a stored column rewrites `links` once. That is trivial at this size, under the migration's lock.
- **Indexes:**
  - `CREATE INDEX links_search_tsv_index ON links USING gin (search_tsv)`.
  - `CREATE INDEX links_embedding_index ON links USING hnsw (embedding vector_cosine_ops)`, with the defaults `m = 16, ef_construction = 64`. Every embedding is NULL at migration time and NULLs are not indexed, so the build is instant.
  - **Partial indexes from #43:**
    - `links_inbox_index ON links (user_id, inserted_at DESC) WHERE triaged_at IS NULL`, for `list_links(filter: :inbox)` and `count_inbox/1`;
    - `links_stuck_index ON links (updated_at) WHERE status IN ('pending','processing') OR enrichment_status = 'pending' OR embedding_status = 'pending'`, for the reaper's three passes.
- **No `CONCURRENTLY`:** the table is small. The migration notes that `@disable_ddl_transaction` with `CONCURRENTLY` would be the route past about 100k rows.

**`Link` schema:**
- `field :embedding, Pgvector.Ecto.Vector, load_in_query: false`. The 4 KB vector is never loaded with lists or broadcasts.
- `field :embedding_model, :string`, `field :embedding_digest, :binary, load_in_query: false`, `field :embedding_status, Ecto.Enum, values: [:pending, :ready, :failed]`, `field :embedded_at, :utc_datetime`.
- **`search_tsv` stays out of the schema.** Ecto would write NULL into it on insert, and Postgres rejects writes to generated columns. `Acervo.Search` queries the `"links"` source schemalessly for it.
- `embedding_changeset/2` casts `embedding`, `embedding_model`, `embedding_digest`, `embedding_status` and `embedded_at`, and validates `embedding_model` at most 200 characters.

- [ ] **Step 1:** Branch `feat/search-schema`. Write tests:
  - Inserting a link through `Library.save_link/2` still works (the generated column is never written).
  - After updating `title: "Inspiração"`, `note: "café"`, a schemaless query `where: fragment("? @@ websearch_to_tsquery('simple', acervo_unaccent(?))", l.search_tsv, ^"inspiracao")` finds it, and `"cafe"` too.
  - `embedding` round-trips a 1024-float vector through `embedding_changeset`. A 3-dimension vector fails at the database (`vector(1024)` rejects it), so assert the raise.
  - `Library.list_links/2` structs have `embedding: nil` (not loaded).
- [ ] **Step 2:** Run them and confirm they fail. Implement. Run `mise exec -- mix ecto.migrate`, then `mix ecto.rollback && mix ecto.migrate`.
- [ ] **Step 3:** In dev, run `EXPLAIN` through Tidewave on a tsquery and on an `ORDER BY embedding <=> $1 LIMIT 50`, and paste both plans in the PR. With 8 dev links the planner will pick sequential scans; that is expected and fine.
- [ ] **Step 4:** Run `mise run precommit`. Commit `feat: add embedding and full-text columns to links`, then open the PR, check CI and merge.

**Acceptance:** the migration runs forward and back, and every existing test passes unchanged.

---

### Task 3: `EmbedLink` — document, worker, enqueue points, reaper  *(Opus)*

**Files:**
- Create: `lib/acervo/search/document.ex`, `lib/acervo/search/embed_link.ex`
- Modify: `lib/acervo/library.ex`, `lib/acervo/collections.ex`, `lib/acervo/ai/enrich_link.ex`, `lib/acervo/library/capture_link.ex`, `lib/acervo/library/extract_content.ex`, `lib/acervo/library/reap_stuck_captures.ex`, `lib/acervo/ai/enrichment.ex` (expose the text cap), `CHANGELOG.md`
- Test: `test/acervo/search/document_test.exs`, `test/acervo/search/embed_link_test.exs`, and additions to `library_test.exs`, `collections_test.exs`, `suggestions_test.exs`, `enrich_link_test.exs`, `capture_link_test.exs`, `extract_content_test.exs`, `reap_stuck_captures_test.exs`

**Interfaces:**
- **`Acervo.Search.Document`:**
  - `@spec build(Scope.t(), Link.t()) :: {:ok, String.t()} | :skip`
  - **Order**, highest signal first so truncation drops only the article's tail. One labelled line per present field, skipping blanks:
    ```
    Title: …
    Site: … (site_name, else the canonical URL's host)
    Author: …
    Collections: name, name   (the scope's collections containing the link, by name)
    Description: …
    Image: …                  (image_description)
    Note: …
    Text: …                   (article text)
    ```
  - **Article text:** `Enrichment.article_text(Library.reader_content(scope, link), link.text_excerpt)`. Add an optional `max` third argument to `article_text/3` and clip to **6,000 characters**.
  - **Whole document:** clip at **8,000 characters**, at a whitespace boundary. That is about 2,000 tokens at the 4-characters-per-token heuristic phase 3 used (Portuguese runs nearer 3.5), and 1/16 of the model's 32k context. Record the heuristic in `@moduledoc`.
  - **Cleaning:** strip NUL and control characters except `\n`, and collapse whitespace per line (reuse the `@control` regex; make the cleaner `@doc false` public in `Enrichment` or move it to a small shared module).
  - **`:skip`:** when title, description, image description, note and text are all blank. A blocked capture with no screenshot has nothing to embed.
  - **No prompt-injection framing:** an embedding model follows no instructions. The content is still untrusted for logging purposes.
  - `@spec digest(String.t(), String.t()) :: binary()` returns `:crypto.hash(:sha256, [model, 0, text])`.
- **`Acervo.Search.EmbedLink`:** `use Oban.Worker, queue: :embed, max_attempts: 5, unique: [period: :infinity, keys: [:link_id], states: [:available, :scheduled, :retryable]]`.
  - **States:** `executing` is left out, so an edit during a run queues a fresh job. `period: :infinity` is phase 3's lesson: a time window lets duplicates through once it expires.
  - `timeout/1` is 30 seconds.
  - `@spec enqueue(Link.t() | Ecto.UUID.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}`
    - **Mark before enqueueing:** in `Repo.transact`, first `update_all(set: [embedding_status: :pending])` on the link, then `Oban.insert(new(%{"link_id" => id}, schedule_in: opts[:delay] || 0))`.
    - `opts[:oban]` names the Oban instance (default `Oban`), for `Acervo.Release`.
    - Call it **inside** the caller's transaction when there is one; `Repo.transact` nests as a savepoint.
  - `@spec enqueue_many([Ecto.UUID.t()], keyword()) :: {:ok, non_neg_integer()}`
    - One `update_all` over the ids, then one `Oban.insert/2` per id in the same transaction. The Basic engine's `insert_all` ignores uniqueness.
    - Ids are sorted first, so concurrent bulk enqueues lock rows in the same order.
  - **Debounce:**
    - Owner edits (note, image description, membership, collection rename or delete) pass `delay: 5`.
    - A burst of edits, or a blur followed by ⌘↩, collapses into the one scheduled job. Uniqueness covers `scheduled`.
    - Pipeline triggers (enrichment finished, capture, content) pass no delay.
    - Text search sees edits at once anyway, because `search_tsv` is generated.
- **`perform/1`:**
  1. Load the link with its user, and the hidden fields (`select_merge` `embedding_digest`; `embedding IS NOT NULL` as a boolean). If it is gone, return `:ok`. If `status != :ready`, reset `embedding_status` from `:pending` to nil and return `:ok`.
  2. `Document.build/2`. On `:skip`, run the same reset and return `:ok`.
  3. `digest = Document.digest(model, text)`. **Dedupe:** if `digest == link.embedding_digest`, `link.embedding_model == model` and an embedding exists, set `:ready` with no call, and return `:ok`. This makes reindex and repeated triggers free.
  4. `AI.embed(scope, %{operation: "embed_link", link_id: id}, text, input_type: :document)`.
  5. **Store** in one transaction:
     - Lock the link (`FOR NO KEY UPDATE`, `user_id` checked). If it is gone, return `:ok`.
     - **Rebuild the document from the locked row and compare digests.** If they differ, the text changed during the call: leave the row `:pending` (the change enqueued a newer job) and return `:ok`. This stops an older job that finishes late from overwriting a newer vector, because a second job can run while the first is still executing.
     - Otherwise write `embedding` (`Pgvector.new/1`), `embedding_model`, `embedding_digest`, `embedding_status: :ready` and `embedded_at`.
     - No broadcast: nothing visible changes.
  6. **Errors:** the same classes as `EnrichLink`, through `Client.classify/1`.
     - Rate limit: snooze with the same backoff (copy the three small functions; don't share a module for them).
     - Transient: `{:error, reason}`; on the last attempt mark `:failed`.
     - Permanent (`:unavailable`, other 4xx): `:failed` and `{:cancel, reason}`.
     - **`:invalid_response` is permanent here:** a wrong vector length is a configuration error. Log it once at `:error` with the model and the expected length.
     - `rescue` logs the exception type and an arity-only stacktrace (`EnrichLink.crashed/5`'s approach) and counts as transient.
- **Enqueue points:**
  - **`EnrichLink`** (enrichment finishes): enqueue `EmbedLink` at every **terminal** outcome, never on a transient retry.
    - After a successful store: inside `store_output/4`, which already holds the link lock.
    - After `reset/2` (`:skip`, not ready).
    - In `give_up/3`.
    - So every link is embedded once enrichment has had its say, with or without an image description.
  - **`CaptureLink.apply_capture/4`:** when it does **not** enqueue `EnrichLink` (the link was already enriched, so this is a re-capture), enqueue `EmbedLink` directly. The `:blocked` and `:not_found` paths enqueue `EmbedLink` too (the worker skips when there is nothing).
  - **`ExtractContent`** (content backfilled): when `Reader.store` saved content and `enrich/1` did not enqueue `EnrichLink`, enqueue `EmbedLink`.
  - **`Library.update_note/3` and `update_image_description/3`:**
    - Wrap them in `Repo.transact`: lock the link (`FOR NO KEY UPDATE`, user-checked, replacing `owned/2`), update, and enqueue with `delay: 5` **only when the changeset changed the field**. A blur with no change costs nothing.
    - Broadcast after commit, as today. Remove the `# phase 4` comment.
  - **`Collections.add_link/3` and `remove_link/3`:**
    - In `Repo.transact`: lock the link `FOR NO KEY UPDATE` (user-checked; this replaces the `Repo.exists?` link check, and closes the window where a concurrent delete made `Repo.insert!` raise on the foreign key).
    - Then check the collection, insert or delete the membership, and enqueue with `delay: 5` only when a row was inserted or deleted.
    - Broadcast after commit.
  - **`Collections.accept_suggestion/2`:**
    - **Change the lock order** to link first. Read the suggestion's `link_id` without a lock (user-checked), lock the link `FOR NO KEY UPDATE`, then lock the suggestion `FOR UPDATE` and re-check that it is still pending and still on that link.
    - When the `collection_links` insert actually inserted (`on_conflict: :nothing` returns a nil id otherwise), enqueue with `delay: 5`.
    - Repointing changes no membership and enqueues nothing.
  - **`Collections.update_collection/3`** (only when `name` changed) **and `delete_collection/2`:**
    - In one transaction: select the member link ids, lock those links `FOR NO KEY UPDATE ORDER BY id`, then update or delete the collection, then `EmbedLink.enqueue_many(ids, delay: 5)`.
    - Locking the links first keeps the lock order consistent with `finish_triage/2`. A delete cascades into suggestions, which `finish_triage/2` updates after taking its link lock.
    - A description change does nothing: collection descriptions are not embedded.
- **`ReapStuckCaptures`:** add a third pass, `reap_embeddings/1`, in the same shape as `reap_enrichments/1`: `embedding_status: :pending`, `updated_at` older than 30 minutes, and no live `EmbedLink` job → `:failed`. No broadcast is needed, but harmless. Update the moduledoc.
- **CHANGELOG `[Unreleased]` `### Added`:** "Each link's text, image description, note and collections are embedded for search."

- [ ] **Step 1:** Branch `feat/embed-link`. Write the failing tests (`FakeEmbedder`, `perform_job/2`, `assert_enqueued`):
  - **Document:**
    - The field order and labels.
    - Collections are the scope's only. Another user's collection with the same link id is impossible, but assert the query filters `user_id`.
    - `content_html` is preferred over the excerpt.
    - The text is clipped at 6,000 and the whole at 8,000 on a word boundary.
    - NUL is stripped.
    - `:skip` for an empty link.
    - The digest changes when the note changes and when the model changes.
  - **Worker:**
    - Success stores a 1024-length vector, the model, the digest, `:ready` and `embedded_at`, and writes exactly one `ai_calls` row with `operation: "embed_link"`.
    - A second run with nothing changed makes **no** embedder call (`FakeEmbedder.calls/0`) and stays `:ready`.
    - A changed note re-embeds.
    - **Late finish:** a stub that updates the note in the database during the call leaves the row `:pending` and the old vector, and returns `:ok`.
    - A stub returning a 512-length vector → `{:cancel, :invalid_response}` and `:failed`.
    - `{:http, 500}` on attempt 1 → `{:error, _}`; on attempt 5 → `:failed`.
    - `:unavailable` → `{:cancel, _}`. Rate limited → `{:snooze, _}`.
    - A deleted link or a not-ready link → `:ok`, with the status reset.
  - **Enqueue points** (each asserts `embedding_status: :pending` **and** `assert_enqueued worker: EmbedLink, args: %{"link_id" => id}`):
    - **Enrichment:** success, skip and final failure enqueue; a transient failure does not.
    - **Capture:** a re-capture of an enriched link enqueues; a first capture enqueues `EnrichLink` and not `EmbedLink`.
    - `ExtractContent` on an enriched link enqueues.
    - **Edits:** a note edit and an image description edit enqueue with a `scheduled_at` about 5 s ahead; saving the same note again enqueues nothing.
    - **Membership:**
      - `add_link` and `remove_link` enqueue, and an idempotent repeat does not;
      - `accept_suggestion` enqueues;
      - renaming a collection enqueues every member, a description edit does not, and deleting a collection enqueues its former members.
    - **Dedupe:** two edits within the window leave one job (`Oban.Job` count 1).
  - **Locks:**
    - `add_link` on a link deleted in another transaction returns `{:error, :not_found}`, not a raise. Lock the link from a separate process with `Repo.transact`, and use `Ecto.Adapters.SQL.Sandbox.allow`.
    - Existing `accept_suggestion` tests still pass after the lock-order change.
  - **Reaper:** a stale `:pending` embedding with no job becomes `:failed`; one with a live job is untouched.
- [ ] **Step 2:** Run them and confirm they fail. Implement. Run `mise run precommit`.
- [ ] **Step 3:** Commit `feat: embed links whenever their searchable text changes`, then open the PR, check CI and merge.

**Review checkpoint A (Opus, after Task 3):**
- **Lock order:** list every transaction touching `links` together with `collection_suggestions` or `collection_links`, and confirm the link row is locked first in each.
- **Status marking:** every enqueue marks the status inside the same transaction as the insert.
- **Debounce:** no enqueue fires on an unchanged save.
- **Logs:** grep the diff for `Logger.` and `inspect(`; no document text or error struct is logged.
- **Late finish:** the digest re-check runs under the lock.

---

### Task 4: Hybrid search context, query cache, reindex  *(Opus; Steps 5–6 are Sonnet-grade)*

**Files:**
- Create: `lib/acervo/search.ex`, `lib/acervo/search/query_cache.ex`, `lib/mix/tasks/acervo.reindex.ex`
- Modify: `lib/acervo/library.ex` (`list_links_by_ids/2`), `lib/acervo/application.ex`, `lib/acervo/release.ex`, `config/config.exs`, `config/test.exs`, `guides/deployment.md`, `CHANGELOG.md`
- Test: `test/acervo/search_test.exs`, `test/acervo/search/query_cache_test.exs`, `test/acervo/release_test.exs`, `test/mix/tasks/acervo.reindex_test.exs`

**Interfaces:**
- **Config:** `config :acervo, :search, embed_timeout: 3_000, max_distance: nil` in `config.exs`, and `embed_timeout: 200` in `test.exs`. `max_distance` is the optional cosine-distance floor for the vector list (Open question 3); nil means no floor until Task 6 calibrates it.
- **`Acervo.Search`:**
  - `@type result :: %{links: [Link.t()], partial: boolean()}`
  - `@spec search(Scope.t(), String.t(), keyword()) :: result()`
    - **Options:** `:collection_id` (an id the caller resolved for this scope), `:source` (`Link` source atom), `:limit` (default 60).
    - **Query:** normalized with `normalize_query/1`. A query under 2 graphemes returns `%{links: [], partial: false}`; the LiveView shows recent links instead.
    - **Flow:**
      1. Start the query embedding (`query_vector/2`) as `Task.Supervisor.async_nolink(Acervo.TaskSupervisor, ...)`.
      2. Run `text_ranks/3` meanwhile.
      3. `Task.yield(task, embed_timeout)`. On `nil` (timeout), `{:exit, _}` or `{:ok, {:error, _}}` → `partial: true`, text-only.
      4. **The timed-out task is not killed:** it is unlinked and bounded by its own `receive_timeout`, so it still records its `ai_calls` row and fills the cache for the next keystroke.
      5. `vector_ranks/3` with the vector, then `fuse/3`, take `limit`, then `Library.list_links_by_ids/2`.
    - **Log:** one line, `search ms=… text=… vector=… partial=… cached=…`, with no query text.
  - `@doc false @spec normalize_query(String.t()) :: String.t()`: `String.replace_invalid`, strip NUL and control characters, collapse whitespace, trim, and cap at 200 characters on a grapheme boundary.
  - `@doc false @spec text_ranks(Scope.t(), String.t(), keyword()) :: [{Ecto.UUID.t(), DateTime.t()}]`
    - A **schemaless** query on `"links"` (for `search_tsv`): `where: l.user_id == type(^user_id, Ecto.UUID) and fragment("? @@ websearch_to_tsquery('simple', acervo_unaccent(?))", l.search_tsv, ^q)`.
    - Plus the collection and source filters, `order_by: [desc: fragment("ts_rank_cd(?, websearch_to_tsquery('simple', acervo_unaccent(?)))", l.search_tsv, ^q), desc: l.inserted_at]`, `limit: 50`, and `select: {type(l.id, Ecto.UUID), type(l.inserted_at, :utc_datetime)}`.
    - `websearch_to_tsquery` accepts any input without a syntax error, so no sanitizing beyond `normalize_query/1` is needed.
  - `@doc false @spec vector_ranks(Scope.t(), Pgvector.t(), keyword()) :: [{Ecto.UUID.t(), DateTime.t()}]`
    - In `Repo.transact`: run `Repo.query!("SET LOCAL hnsw.ef_search = 100")` and `Repo.query!("SET LOCAL hnsw.iterative_scan = relaxed_order")`. These constant strings are the only raw SQL.
    - Then a materialized subquery: `where user_id, embedding_model == ^AI.embedding_model(), not is_nil(embedding)`, plus the collection and source filters, `order_by: fragment("? <=> ?", l.embedding, ^vector)`, `limit: 50`, selecting the id, `inserted_at` and distance.
    - The outer query re-sorts by distance (`relaxed_order` may return slightly out of order) and applies `max_distance` when set.
    - **Why `iterative_scan`:** HNSW filters `user_id` after the index scan. Without it, a filtered query can return fewer than 50 rows. With a small table the planner uses an exact sequential scan anyway; both are correct.
  - `@doc false @spec fuse([{id, DateTime.t()}], [{id, DateTime.t()}], pos_integer()) :: [id]`
    - A pure function: `score = Σ 1 / (k + rank)` over both lists, with 1-based ranks and k = 60.
    - Sort by score descending, then `inserted_at` descending, then id, so the order is total and deterministic.
  - `@doc false @spec query_vector(Scope.t(), String.t()) :: {:ok, Pgvector.t(), cached? :: boolean()} | {:error, term()}`
    - Check `QueryCache` first.
    - On a miss, call `AI.embed(scope, %{operation: "embed_query", link_id: nil}, q, input_type: :query, receive_timeout: 10_000)` and cache it on success.
  - **Collection scoping is safe by construction.** Every query filters `user_id`, so another user's `collection_id` yields nothing (tested).
  - **No soft-deleted states exist.** Deleting a link deletes the row. Pending and failed links have no embedding (the worker embeds only `:ready` links) and little or no text, so they rarely match and are not filtered further. A test pins this.
  - **No highlighting in 0.9.0.** Cards show the title and description, not a snippet. `ts_headline` over the excerpt for 60 rows per keystroke is not cheap, and vector hits have no matching words to highlight (Open question 5).
- **`Acervo.Library.list_links_by_ids(Scope.t(), [Ecto.UUID.t()]) :: [Link.t()]`:** the same preloads as `list_links/2` (first image, collections, pending suggestions), `user_id` filtered, returned in the given order.
- **`Acervo.Search.QueryCache`:** a GenServer owning a named `:set`, `:public`, `read_concurrency: true` ETS table.
  - **Key:** `{user_id, model, normalized_query}`. **Value:** `{Pgvector binary, inserted_at_ms}`.
  - `fetch(key) :: {:ok, Pgvector.t()} | :miss` treats entries older than **10 minutes** as misses. `put(key, vector)`.
  - A sweep every 60 s deletes expired entries; when the table holds over **500** entries it deletes the oldest half.
  - **Why ETS:** Cachex is not a dependency and the need is tiny. The repeats are re-runs of the same query (submit after debounce, reconnects, back/forward, opening a result and returning). 500 × about 4.2 KB is about 2 MB at most on the 1 GB machine.
  - **Why it is keyed per user:** a shared key would let one account time another's queries, even if harmless today.
  - Start `{Task.Supervisor, name: Acervo.TaskSupervisor}` and `Acervo.Search.QueryCache` in `application.ex`, before the endpoint.
- **Reindex** (Steps 5–6):
  - `Acervo.Release.reindex(opts \\ []) :: non_neg_integer()`
    - Same shape as `backfill_enrichment/0`: the repo plus a queue-less `Acervo.Release.Oban`.
    - `EmbedLink.enqueue_many(stale_embeddings(repo, opts), oban: Acervo.Release.Oban)`. It prints and returns the count.
    - `all: true` re-enqueues every ready link, for a change in the document format. The worker's digest check still skips links whose document and model are unchanged, so this is cheap.
  - `@doc false stale_embeddings(repo, opts) :: [Ecto.UUID.t()]`: `status == :ready` and (`embedding_model IS DISTINCT FROM ^model` or `embedding IS NULL` or `embedding_status == :failed`) and `embedding_status IS DISTINCT FROM :pending`, newest first.
  - `mix acervo.reindex [--all]` (`lib/mix/tasks/acervo.reindex.ex`): `Mix.Task.run("app.config")`, then `Acervo.Release.reindex(all: "--all" in args)`. It starts no queues, so the dev server's `embed` queue does the work. `@shortdoc "Re-embeds links whose embedding is missing, failed or from another model"`.
- **`guides/deployment.md`:**
  - Under Secrets: `OPENROUTER_API_KEY` (required, already staged), and `ACERVO_EMBEDDING_MODEL` (optional; must return 1024 dimensions, or the column and migration must change).
  - **One-off tasks → "Search reindex":** run `fly ssh console -a acervo-app -C "/app/bin/acervo eval 'Acervo.Release.reindex()'"` after deploying 0.9.0. Check progress with `SELECT embedding_status, count(*) FROM links GROUP BY 1`.
  - **"Changing the embedding model":** set the secret, deploy, then reindex. Meanwhile, text search keeps working and vector results come only from links already re-embedded with the new model.
  - **"Sizes"** (for the shared cluster and the 1 GB machine):
    - **Per link:** a `vector(1024)` is 4,104 bytes, stored out of line in TOAST.
    - **HNSW:** an element of that size takes about one 8 KB page, so the index is about 8 MB per 1,000 links (80 MB at 10,000). The `search_tsv` and GIN index add well under 1 MB per 1,000 links.
    - **Build:** at migration time every embedding is NULL, so the build is instant. Later inserts update the graph incrementally. `maintenance_work_mem` (64 MB in dev) only matters for a rebuild past about 8,000 links.
    - **App:** the cache is 2 MB at most, and a search holds about 40 KB transiently for the vector list.
    - **Later:** `halfvec(1024)` would halve all of this if it ever matters.
- **CHANGELOG:** `### Migration`: the reindex command.

- [ ] **Step 1:** Branch `feat/hybrid-search`. Write the failing tests. Seed vectors directly with `Repo.update_all(set: [embedding: Pgvector.new(FakeEmbedder.axis(i)), embedding_model: AI.embedding_model()])`, and stub the query vector with `FakeEmbedder.stub/1`:
  - **`fuse/3`** (pure):
    - an item in both lists beats items in one;
    - rank 1 in one list beats rank 2 in the same list;
    - ties fall back to the newer `inserted_at`;
    - an empty vector list gives the text order.
  - **RRF end to end:**
    - Link A: title matches the words, vector far.
    - Link B: no word match, vector = query axis.
    - Link C: matches both.
    - Expect C, then A and B in the order the RRF formula gives (compute it in the test), with `partial: false`.
  - **Image description:** a link whose only match is its `image_description` is found by both text and vector.
  - **Fallback:**
    - The stub returns `{:error, {:http, 500}}` → text results, `partial: true`.
    - The stub sleeps 500 ms (above the 200 ms test timeout) → `partial: true`, and the call returns in under 400 ms.
    - The `ai_calls` row for the slow call still appears (`eventually` poll, at most 1 s).
  - **Scoping:**
    - user B never sees user A's links in either list;
    - `collection_id` limits both lists;
    - user B passing user A's `collection_id` gets `[]`;
    - `source: :youtube` filters.
  - **Model isolation:** a link embedded with `embedding_model: "other:model"` is absent from vector results and still found by text.
  - **Accents:** `"inspiracao"` finds `"Inspiração"`; `"CAFÉ"` finds `"café"`.
  - **Injection and odd input:** none of these raise. Each returns only the scope's rows, and afterwards `Repo.aggregate(Link, :count)` is unchanged:
    - `"'); DROP TABLE links; --"`, `"\" OR 1=1 --"`, `"foo:* & !bar <-> baz"`, `"\\"`, `"%_"`, `"\u0000abc"`, `"-"`, `"or"`;
    - a 10,000-character string (capped to 200 before use);
    - emoji, and a right-to-left string.
  - **Short query:** `"a"` gives `%{links: [], partial: false}` with no embedder call.
  - **Cache:**
    - the same query twice makes one embedder call and one `ai_calls` row;
    - a different user makes a second call;
    - an entry older than 10 min is a miss (inject the clock through an option).
  - **Release:** `stale_embeddings/2` picks nil, failed and other-model rows; skips pending and current ones; with `all: true` it picks every ready link.
  - **Mix task:** `Mix.Task.rerun("acervo.reindex")` enqueues for a stale link (`assert_enqueued`).
- [ ] **Step 2:** Run them and confirm they fail. Implement Steps 1–4's interfaces.
- [ ] **Step 3:** Grep the diff for `Repo.query`, `fragment(` and `"#{`: no user value is interpolated into SQL.
- [ ] **Step 4:** In dev, through Tidewave, run text-only checks of `Acervo.Search.search/3` on the 8 dev links, with no paid calls. Dev uses the real embedder, so set `Application.put_env(:acervo, :openrouter, api_key: nil)` for the session first: the embedder returns `:unavailable` and the search returns `partial: true`. Restore the key afterwards.
- [ ] **Step 5 (needs Task 3 merged):** Implement `reindex/1`, `stale_embeddings/2` and the mix task, and update the deployment guide and CHANGELOG.
- [ ] **Step 6:** Run `mise run precommit`. Commit `feat: hybrid search with reciprocal rank fusion`, then open the PR, check CI and merge.

**Review checkpoint B (Opus, after Task 4):**
- SQL is parameterized everywhere, and `SET LOCAL` runs only inside a transaction.
- The timed-out task is unlinked and bounded.
- Logs carry no query text.
- The vector branch filters `embedding_model`.
- `list_links_by_ids/2` filters `user_id`.

---

### Task 5: Search UI — dock pill, `/search` routes, results column, guides  *(Opus)*

**Files:**
- Modify: `lib/acervo_web/router.ex`, `lib/acervo_web/live/archive_live.ex`, `lib/acervo_web/components/archive_components.ex`, `lib/acervo_web/components/guide_components.ex`, `assets/css/archive.css`, `guides/features.md`, `priv/gettext/**`, `CHANGELOG.md`
- Add icons: `assets/vendor/lucide/search.svg` and `zap-off.svg`, from lucide-static 1.55.0 (`https://cdn.jsdelivr.net/npm/lucide-static@1.55.0/icons/`), normalized like the others. Note them in `assets/vendor/lucide/README.md`.
- Test: `test/acervo_web/live/search_test.exs`, and additions to the dock and guide tests

**Interfaces:**
- **Routes:**
  - `live "/search", ArchiveLive, :search`, `live "/search/l/:id", ArchiveLive, :search_link`, `live "/search/l/:id/web", ArchiveLive, :search_link_web`.
  - Query params: `q` (the query) and `in` (a collection slug, optional). This is the spec's `/search?q=`, extended with the scope.
- **`ArchiveLive`:**
  - **Filter:** `{:search, q, collection | nil}`. `handle_params` resolves `in` with `Collections.get_collection_by_slug!/2`; an unknown slug flashes "Not found." and patches to `/search?q=…`. `@collection` holds the scoping collection, so `list_path`, `link_path` and `web_path` get search clauses that carry `q` and `in`.
  - **Results:**
    - Under 2 characters: stream recent links (`Library.list_links/2` with `filter: :all`, or `{:collection, id}` when scoped).
    - Otherwise: `start_async(:search, fn -> Search.search(scope, q, collection_id: ...) end)`, keeping the current cards until the result arrives.
    - `handle_async(:search, {:ok, %{links:, partial:}})` resets the stream and assigns `search_partial`.
    - A crash (`{:exit, _}`) keeps the cards, assigns `partial: true`, and logs nothing extra.
    - Opening a result (`/search/l/:id?q=…`) must **not** re-run the search: `reset?` compares `q` and the scope only.
  - **Live updates:**
    - `{:link_updated, _}` updates only cards already listed (`stream_insert(..., update_only: true)` in `restream/2` for the search filter).
    - `{:link_created, _}` is ignored on search.
    - `{:link_deleted, _}` behaves as today.
  - **Events:**
    - `toggle_search` opens or closes the pill. The form starts with the current `q`, and the scope is the open collection when on a `/c/:slug…` route.
    - `search` (`%{"q" => q}`, from `phx-change` debounced 400 ms and from `phx-submit`) → `push_patch(to: ~p"/search?#{params}", replace: true)`. Replacing keeps typing out of history; ↩ submits at once.
    - `clear_search_scope` drops `in`. `close_search` (Esc) hides the pill and keeps the results and URL.
    - `open_search` comes from the keyboard.
  - **Dock:** `active` becomes `:search` on search routes.
  - **`.Shortcuts`:**
    - `/` (no modifiers, outside fields, no `.popover[open]`) pushes `open_search`.
    - ⌘K on macOS / Ctrl K elsewhere, anywhere including fields, toggles it (`preventDefault`). Detect the platform as `.SubmitShortcut` does.
    - Neither conflicts with an existing key (see "What the deps say").
- **`ArchiveComponents`:**
  - **Dock:** a search item `#dock-search` between Acervo and Inbox, as the spec's dock order says. A `<button>` with `lucide-search`, `phx-click="toggle_search"`, `aria-controls="search-pill"`, `aria-expanded`, and tooltip `gettext("Search")`. It shows its label when active, like Acervo and Inbox.
  - **`search_pill/1`** (attrs `form`, `scope` (collection or nil), `partial`, `loading`): the same `.float` shell as `add_pill/1`, with `#search-pill`, `phx-window-keydown="close_search"`, `phx-key="Escape"` and the leaving transition. Inside:
    - **Icon:** `lucide-search`, which pulses faintly while `loading` (respect `prefers-reduced-motion`).
    - **Form:** `#search-form`, `phx-change="search"`, `phx-submit="search"`.
    - **Input** `#search-query`: `name="q"`, `type="search"`, `phx-debounce="400"`, `maxlength="200"`, `autocomplete="off"`, `enterkeyhint="search"`, placeholder `gettext("Describe a link")`, focused on mount.
    - **Scope chip** `#search-scope`, when scoped: `lucide-folder` plus the collection name, with a ✕ (`.chip-x`, `phx-click="clear_search_scope"`, `aria-label={gettext("Search everything")}`).
    - **Partial icon** `#search-partial`, when partial: `lucide-zap-off` at `--faint`, with `title`/`aria-label` `gettext("Only matching words")`.
    - `⌘K` in the `.float-kbd` slot instead of ↵ (`mod_key/1`).
- **Results column:** the list column, with id `column-search`, title `gettext("Search")`, no description paragraph, and the existing `card/1`s.
  - Empty: `.empty` reads `gettext("Nothing found.")` when `q` has 2 or more characters. With a shorter query, the recent cards show and there is no empty text.
  - No count line and no "results for …" text. The pill already shows the query.
- **CSS** (tokens only):
  - `.float .chip` sized for the pill.
  - `#search-partial` at `color: var(--faint)`.
  - Check the pill width at 400 px: the chip truncates with an ellipsis before the input shrinks below about 8 characters.
- **Guides:**
  - **In-app:** a new `guide-search` section, with rows:
    - `lucide-search` "Describe what you remember: words, what the image shows, your note.";
    - `lucide-folder` "Inside a collection, search looks only there. ✕ widens it.";
    - `lucide-zap-off` "This icon means only matching words were found this time."
  - **Shortcuts table:** `/` "Search" and `⌘K` "Search, from anywhere".
  - **`guides/features.md`:**
    - a `## Search` section: the pill, debounce, routes, scope, recent links for short queries, the partial fallback, `EmbedLink` and what is embedded, `search_tsv`, RRF, the cache, `mix acervo.reindex`;
    - two shortcut rows (`.Shortcuts` → `open_search`).
  - **CHANGELOG `### Added`:** "Search: describe a link in your own words and find it, even by what its image shows. Open it with `/` or ⌘K."

- [ ] **Step 1:** Branch `feat/search-ui`. Write LiveView tests by element id (no network: `FakeEmbedder` default vectors, plus seeded vectors where order matters):
  - `#dock-search` opens `#search-pill`. Esc (`close_search`) closes it.
  - Changing `#search-form` with `q: "praia"` patches to `/search?q=praia`, and the matching card `#link-<id>` renders after `render_async/1`.
  - A query of 1 character shows recent links.
  - Opening a result patches to `/search/l/:id?q=praia`, and the link column opens without re-running the search (the embedder call count does not change).
  - From `/c/:slug`, opening search scopes it: `#search-scope` shows, and a link outside the collection is absent. `clear_search_scope` widens it.
  - A stubbed embedder failure shows `#search-partial`, with text results still listed.
  - "Nothing found." shows for a query with no match.
  - A broadcast `{:link_updated, link}` for a listed link re-renders its card; `{:link_created, _}` adds nothing.
  - `/search?q=x&in=unknown` flashes "Not found."
  - The guide shows `#guide-search` and the two shortcut rows.
- [ ] **Step 2:** Run them and confirm they fail. Implement. Fill in pt_BR. Run `mise run precommit`.
- [ ] **Step 3:** The controller checks in Chrome on `:4200` with the real embedder (after `mix acervo.reindex` in dev):
  - studio and dark themes, and a 400 px viewport;
  - `/` and ⌘K, typing, ↩, Esc;
  - opening a result and coming back;
  - scoping;
  - partial (unset the key for the session through Tidewave).
  - The pill must match the add pill's metrics.
- [ ] **Step 4:** Commit `feat: search from the dock`, then open the PR, check CI and merge.

**Review checkpoint C (controller, after Task 5):** the "clean and minimal" bar.
- No explanatory copy in the column, and no result counts.
- Only icons with tooltips for scope and partial.
- Nothing jumps while results load: the cards stay until the new ones arrive.
- The pill matches the add pill.

---

### Task 6: Release 0.9.0, real-data verification, production reindex  *(controller)*

- [ ] **Step 1: Dev verification** (real key, dev server on `:4200`, Chrome):
  - Run `mix acervo.reindex` and watch `SELECT embedding_status, count(*) FROM links GROUP BY 1` reach all `ready`.
  - **Done-when probe:** for at least three links, search in free words that appear **only** in their `image_description` (not in the title or text), in Portuguese and in English. Each must come first or second.
  - Search by a word from a note, by a collection name, and inside a collection.
  - **Calibrate `max_distance`** (Open question 3): print the cosine distance of the top 10 vector hits for a few matching queries and for two nonsense queries (`"xyzzy plover"`). If the two populations separate clearly, set the floor between them in `config.exs` and note the numbers in the PR. Otherwise leave it nil.
  - Run `Acervo.Release.ai_costs(1)` and note the embedding cost per link and per query.
- [ ] **Step 2:** Branch `chore/release-0.9.0`.
  - Set `version: "0.9.0"`.
  - Curate the CHANGELOG into `## [0.9.0] - <date>` with a one-line summary, `### Added` and `### Migration`:
    - the new link columns and indexes;
    - `OPENROUTER_API_KEY` (required) and `ACERVO_EMBEDDING_MODEL` (optional);
    - the reindex command.
  - Update the spec:
    - Data model: `embedding_status`, `embedding_digest`, `embedded_at`; the `search_tsv` fields;
    - `EmbedLink`: its document and triggers per this plan;
    - Search: scope, `max_distance`, the cache.
  - Run `mise run precommit`. Commit `chore(release): prepare 0.9.0`, then open the PR, check CI and merge.
- [ ] **Step 3:** Confirm `OPENROUTER_API_KEY` is staged (`fly secrets list -a acervo-app`, names only), because the app now refuses to boot without it. Tag `v0.9.0`, push, and run `gh release create v0.9.0 --title 0.9.0 --notes-file <section>`. Watch `Deploy release`, then check `/health`.
- [ ] **Step 4: Production.**
  - Run `Acervo.Release.reindex()` and watch the `embedding_status` count until nothing is `pending`.
  - Check `SELECT pg_size_pretty(pg_relation_size('links_embedding_index')), pg_size_pretty(pg_total_relation_size('links'))`, and the machine's memory in `fly machine status` / metrics during the reindex.
  - Run the done-when probe on one real link.
  - Run `ai_costs(1)`.
  - Check `fly logs` for any query text, document text or key (there must be none).
- [ ] **Step 5:** Close #43 with a comment linking the release and stating the measured cost per link and per query. File follow-up issues for anything deferred (Open questions), following the "track work in GitHub issues" rule. The repo is public, so include no sensitive data.

---

## Open questions

1. **Does OpenRouter honor `dimensions` for `voyageai/voyage-4-lite`?** LLMDB lists the model (embeddings, $0.02/M, 32k context) but has no dimension metadata. Voyage 4's native default is 1024, so the plan requests 1024 and asserts the length either way. If the spike shows OpenRouter **rejects** `dimensions`, the plan drops the parameter and keeps the assertion. If it returns **another length**, we need a different model. The closest supported OpenRouter models with 1024 dimensions:
   - `openai/text-embedding-3-small` with `dimensions: 1024` (same price, $0.02/M; LLMDB confirms 1..1536);
   - `mistralai/mistral-embed-2312` (fixed 1024, $0.10/M).
   Owner's call if it comes to that.
2. **`input_type` (query vs document).** Voyage is trained for asymmetric retrieval, so the plan sends `document` for links and `query` for searches when OpenRouter accepts it, and drops it otherwise. The spike decides; flagged in case the owner prefers symmetric embeddings.
3. **A similarity floor for the vector list.** Pure top-50 vector search always returns 50 neighbors, so a query matching nothing still fills the column through RRF. The plan adds an optional `max_distance`, calibrated on real data in Task 6, or left off if the distributions don't separate. Should a query with no real match show "Nothing found." (floor on), or always show the closest links (floor off)?
4. **Shortcuts.** The plan binds both `/` (outside fields) and ⌘/Ctrl K (anywhere, toggles). Keep both, or only one?
5. **Highlighting.** None in 0.9.0, because cards show the title and description, not snippets, and vector hits have no matching words. A follow-up could add a `ts_headline` snippet line on search cards only. Wanted?
6. **Spec divergences to confirm:**
   - `search_tsv` also indexes `site_name` and `author` (weight C).
   - The embedded document adds collection names and a longer article text: 6,000 characters of the article, 8,000 in total (about 2,000 tokens), against the spec's "first 2,000 characters of the excerpt".
   - The vector branch ignores rows from another model.
   Task 6 updates the spec to match.
7. **Document budget.** Is about 2,000 tokens right? voyage-4-lite takes 32k. Longer documents capture more of an article, but they dilute the vector toward its body and away from the title and image description, which are what people remember. The cost is negligible either way.
8. **Search scope default.** Opening search inside a collection scopes it to that collection (#43), with a ✕ to widen. Should `⌘K` from anywhere else always search everything (the plan's behavior)?
9. **Prefix matching.** `websearch_to_tsquery` does not match partial words ("inspira" does not find "inspiração") while typing. The vector branch partly covers this. Add last-word prefix matching later if missed?

## Decisions (controller)

*(Answers to the open questions; they override the plan text where they differ.)*

## Decisions (controller, 2026-10-18)

Answers to the open questions above; they override the plan text where they differ.

1. **Embedding model:** keep `openrouter:voyageai/voyage-4-lite` at 1024 if the spike confirms it returns 1024-dimension vectors. If OpenRouter rejects or ignores `dimensions`, use `openrouter:openai/text-embedding-3-small` with `dimensions: 1024`; it is designed for shortened vectors.
2. **No-match searches:** apply a similarity cutoff to the vector side only, tuned in the spike on real dev links. Text matches are always kept. A query with neither shows the quiet "Nothing found." state.
3. **Shortcuts:** both `/` and ⌘K/Ctrl+K open search, unless the `.Shortcuts` hook shows a conflict.
4. **Highlighting:** none in 0.9.0, to keep the cards clean.
5. **Spec changes:** accepted. Full-text also covers site and author, and the embedded text includes collection names and about 2,000 tokens of article text. Update the spec in Task 6.
