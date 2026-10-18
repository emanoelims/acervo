# Acervo — product design

Date: 2026-10-18 · Status: approved

Acervo is a personal archive of links found on the internet: Instagram and X
posts, YouTube videos, blogs and sites. Saving a link captures a visual preview
and stores its images. Claude describes what the images show and suggests
collections, and free-text search finds links by meaning, not only by words.

Sibling project `../leitor` is the reference for conventions, authentication,
the LLM stack, themes, and components.

## Goals

- Save any URL in one step, from desktop now and from the phone later.
- Show a visual preview for every link and keep images even if the source
  disappears or blocks access.
- Organize links into collections, where one link can belong to many. The AI
  suggests collections and the owner decides.
- Find links by describing them in free text, including what appears in their
  images.
- Look and feel: the column layout of the approved prototype, with leitor's
  theme mechanics and components.

## Non-goals (for now)

- Multiple users with per-account AI keys, credits, or billing. Data is still
  scoped per account, so this can be added later.
- Video transcripts or full-page archives. Capture is extensible so they can be
  added as new extractors.
- Periodic AI reorganization of the whole archive. Only per-link suggestions
  for now.
- Browser extension or bookmarklet.

## Decisions

| Topic | Decision |
|---|---|
| Users | Single owner for now, multi-user ready: every context function takes `%Scope{}` first |
| Registration | Magic-link `phx.gen.auth` as in leitor. Registration is restricted to emails in `ACERVO_ALLOWED_EMAILS` |
| Organization | Collections with many-to-many membership. No tags |
| AI suggestions | Every new link lands in the **inbox** with suggested collections. The owner accepts chips, picks others, and marks it done |
| Search | Hybrid: pgvector cosine similarity plus Postgres full-text, merged with Reciprocal Rank Fusion |
| Searchable text | Title, description, page text excerpt, owner's note, and a Claude-written description of the preview image |
| Chat model | Claude through ReqLLM with `ANTHROPIC_API_KEY`. Haiku 5.5 by default, configurable |
| Embeddings | `openrouter:voyageai/voyage-4-lite` with `OPENROUTER_API_KEY`, 1024 dimensions requested explicitly, configurable with `ACERVO_EMBEDDING_MODEL` |
| Jobs | Oban on Postgres |
| Images | WebP bytes in Postgres behind an `Acervo.Storage` behaviour, so Tigris can replace it later |
| Layout | Equal-width Miller columns, Finder style (prototype option **A**) |
| Theme | New default theme `studio` built from the prototype tokens. Leitor's themes remain available |
| Font | Inter by default. Font, theme, and accent are configurable like leitor |
| Mobile capture | Last phase: personal API token, iOS Shortcut, PWA `share_target` for Android |
| Deploy | Fly, deployed only from stable GitHub releases, as in leitor |

## Architecture

```
            ┌──────────────┐   save_link    ┌──────────────┐
 paste / +  │  LiveViews   │ ─────────────▶ │   Library    │── Oban: CaptureLink
 share API  │ (columns UI) │ ◀── PubSub ─── │   context    │── Oban: EnrichLink
            └──────────────┘                └──────────────┘── Oban: EmbedLink
                   │ search                        │
                   ▼                               ▼
            ┌──────────────┐               ┌──────────────┐
            │    Search    │──  Embedder ─▶│  OpenRouter  │
            │   context    │               └──────────────┘
            └──────────────┘   AI.Client ─▶ Anthropic (Claude)
```

| Context | Responsibility |
|---|---|
| `Acervo.Accounts` | Users, magic-link sessions, `Scope`, allowlist |
| `Acervo.Library` | Links, images, URL normalization, capture pipeline, extractors |
| `Acervo.Collections` | Collections, membership, suggestions, inbox triage |
| `Acervo.Search` | Hybrid query and Reciprocal Rank Fusion |
| `Acervo.AI` | Claude calls (enrichment) behind a behaviour, and the `Embedder` behaviour |
| `Acervo.Storage` | Image persistence behaviour. `Acervo.Storage.Database` is the first implementation |

Each extractor, embedder, AI client, and storage implementation sits behind a
behaviour, so tests can swap in fakes and later providers need no change at the
call sites.

## Data model

All tables use UUID v7 primary keys and `user_id` ownership, like leitor.

**`links`**
- `url`: as submitted.
- `canonical_url`: normalized, with a unique index on `(user_id, canonical_url)`.
- `source`: enum `generic | youtube | instagram | x`.
- `status`: enum `pending | processing | ready | failed`.
- `capture_error`: a short reason, with no stack traces.
- Content: `title`, `description`, `author`, `site_name`, `published_at`,
  `text_excerpt` (truncated to 8,000 characters).
- `image_description`: written by Claude, editable by the owner.
- `note`: written by the owner.
- `triaged_at`: `nil` means the link is in the inbox.
- `embedding`: `vector(1024)`, nullable. An HNSW index uses `vector_cosine_ops`.
- `embedding_model`: the model that produced the vector, used for reindexing.
- `search_tsv`: a generated `tsvector` built with the `simple` configuration
  from title, description, excerpt, image description and note, with a GIN
  index. Accents are removed through an `IMMUTABLE` SQL wrapper,
  `acervo_unaccent(text)`, around `unaccent('unaccent', ...)`, because
  `unaccent` itself is only `STABLE` and cannot be used in a generated column.
  Queries use the same wrapper.
- Timestamps.

**`link_images`**
- `link_id`, `position`, `kind`: enum `preview | screenshot`.
- `content_type`, `bytes` (WebP, at most 1600 px on the long side), `width`,
  `height`, `sha256`.
- Served by `GET /images/:id`. The route is authenticated, checks the scope,
  and sends `Cache-Control: private, max-age=31536000, immutable`.

**`collections`**
- `name`, `slug`, `description`, `position`.
- Unique `(user_id, slug)`.

**`collection_links`**
- `collection_id`, `link_id`, `source`: enum `manual | suggestion`,
  `inserted_at`.
- Unique on the pair.

**`collection_suggestions`**
- `link_id`, either `collection_id` or `proposed_name`, `reason` (one short
  line), `status`: enum `pending | accepted | dismissed`.
- When a suggestion with a `proposed_name` is accepted, a collection is
  created; the match is on the normalized name, so an existing collection with
  that name is reused. Other pending suggestions with the same normalized name
  are repointed to the new collection.

**Oban:** the standard `oban_jobs` table, with queues `capture` (concurrency 4),
`ai` (2) and `embed` (4).

## Capture pipeline

`Library.save_link(scope, url, opts \\ [])`:
1. Validates `http`/`https`, normalizes the host, strips the fragment, and drops
   tracking parameters (`utm_*`, `fbclid`, `gclid`, `igsh`, `igshid`, `si`, `s`
   on x.com, `feature` on youtube).
2. If `(user_id, canonical_url)` exists, returns `{:ok, link, :existing}`.
3. Otherwise it inserts a `pending` link and enqueues `CaptureLink` in the same
   transaction, then returns at once.

**`CaptureLink`**
- Picks the first extractor whose `match?/1` accepts the URI, falling back to
  `Generic`.
- Each `extract/2` returns `{:ok, %Capture{}}`, or `{:error, reason}` where the
  reason is `:blocked`, `:not_found`, `:timeout` or `{:http, status}`.
- It downloads up to 4 images, validates them with `Image`, converts them to
  WebP, and stores them.
- It sets `status: :ready`, broadcasts `{:link_updated, link}`, and enqueues
  `EnrichLink`.

**Extractors**

| Extractor | Approach |
|---|---|
| `Generic` | Fetches HTML (at most 3 MB) and parses Open Graph, Twitter Card, `<title>`, meta description, and the main text with `LazyHTML` |
| `YouTube` | The public oEmbed endpoint plus `i.ytimg.com/vi/<id>/maxresdefault.jpg`, falling back to `hqdefault` |
| `X` | The public `publish.twitter.com/oembed` endpoint for text and author; media through Open Graph when available |
| `Instagram` | Open Graph through `Generic` with a crawler user agent. A login wall counts as `:blocked` |

**Failures**
- Transient errors (timeouts, 5xx) retry with Oban backoff, up to 5 attempts.
- `:blocked` and `:not_found` do not retry. The link becomes `ready` with
  `capture_error` set, and the UI offers to add a screenshot.
- A screenshot upload uses LiveView uploads, goes through the same `Image`
  normalization, and re-enqueues `EnrichLink`.

**SSRF guard (`Acervo.Library.SafeFetch`)**
- Resolves the host and rejects loopback, private, link-local, CGNAT, multicast
  and IPv6 ULA/link-local addresses.
- Repeats the check on every redirect, with at most 5 redirects.
- Allows only ports 80 and 443.
- Limits connect and receive time to 10 s and caps the body size.
- All extractor and image downloads go through it.

## AI enrichment

`EnrichLink` makes one Claude call through ReqLLM `generate_object` with a
schema.

**Input:**
- The link text fields.
- The first image, as base64 WebP.
- Up to 50 collections, each with its name, description and three example
  titles.

**Output:**
- `image_description`: one to three sentences in the page's language,
  describing what is visible.
- `suggestions`: one to three entries, each `{collection_slug | new_name, reason}`.
- `language`.

**Rules:**
- Suggestions never auto-apply.
- After a failure the job retries up to 3 times. The link stays usable without
  enrichment, and the UI simply shows no chips.
- Editing the note or `image_description` enqueues `EmbedLink` again.

**`EmbedLink`**
- Builds the document from: title, site, author, description, image
  description, note, and the first 2,000 characters of the excerpt.
- Calls the `Embedder` with `dimensions: 1024`.
- Asserts that the vector length is 1024 and stores the vector and model id.

**`mix acervo.reindex`** re-enqueues `EmbedLink` for links whose
`embedding_model` differs from the configured one.

## Search

`Search.search(scope, query, opts)`:
- Options: `collection_id`, `source`, and `limit` (default 60).
- **Text:** `websearch_to_tsquery('simple', acervo_unaccent(query))`, ranked with
  `ts_rank_cd`, top 50.
- **Vector:** embeds the query and returns the top 50 by
  `embedding <=> query_vector`.
- **Fusion:** `score = Σ 1 / (60 + rank)` across both lists, sorted by score
  descending, with ties broken by `inserted_at` descending.
- **Fallback:** if embedding fails or times out (3 s), it returns text-only
  results flagged `partial: true`. The UI shows a subtle icon.
- The LiveView debounces input by 400 ms. Queries shorter than 2 characters
  show recent links instead.

## Interface

The layout follows the approved prototype, option A
([`2026-10-18-acervo-prototype.html`](2026-10-18-acervo-prototype.html)).

**Columns**
- Equal-width columns, each `max(340px, (viewport - gutters) / 3)`.
- The container scrolls horizontally, and opening a column scrolls it into
  view.
- The URL reflects the path, so links can be shared and the back button works:
  `/`, `/c/:slug`, `/c/:slug/l/:id`, `/inbox`, `/inbox/l/:id`, `/all`,
  `/all/l/:id`, `/search?q=`.
- **Column 1:** "Acervo", a short intro sentence with live counts as
  underlined links, then the navigation (Inbox with a dot and count, All,
  collections with counts) and an active-bar indicator.
- **List columns:** a title with `›` and a round `···` menu (rename, describe,
  delete). Then a description paragraph and a divider, then cards. Cards come
  in three kinds:
  - Image card: the image over its own blurred copy.
  - Text card: date, title and a two-line summary.
  - Video card: date, title and a 16:9 thumbnail with a play badge.
  - Every card carries the source icon in its top-right corner.
- **Link column:** a short title, the visual, a meta line, collection chips
  (filled) and suggestion chips (dashed with ✦), the AI description, the note,
  and round icon actions (open original, note, delete).
- **"↑ Column title" pill:** appears after a column scrolls past 150 px and
  scrolls it back to the top.

**Inbox**
- Same cards, with suggestion chips and a ✓ done button.
- Tapping a chip accepts it.
- "Accept all" accepts every pending suggestion of the selected links and marks
  them done.

**Dock**
- A floating glass pill at the bottom center. Home and the active section show
  icon plus label; the other items show only an icon.
- Items: Acervo, Search, Inbox (with an amber dot when non-empty), Settings,
  and Add (+).
- Search and Add open floating input pills above the dock, and `Esc` closes
  them.
- Pasting a URL anywhere outside an input triggers `save_link`.

**Principles:** little text, no repeated text, icons with tooltips instead of
labels, near-invisible borders (6% black), generous whitespace, and short
transitions with leitor's ease curve.

**Appearance (ported from leitor)**
- Themes: `studio` (new default), `light`, `sepia`, `snow`, `dark`, `ink`.
  `auto` maps to `studio` or `dark` by `prefers-color-scheme`.
- Accents: `vermilion`, `cobalt`, `moss`, `graphite`.
- Fonts: Inter (default), Schibsted Grotesk, Atkinson Hyperlegible Next and
  Newsreader, all self-hosted.
- Stored in `localStorage` (`acervo:appearance`). The server renders the default
  appearance on `<html>`, so default users never see a flash. Saved choices apply
  as soon as `app.js` runs, without an inline script, per AGENTS.md.
- The theme switch keeps leitor's circular View Transition.

**`studio` tokens:** `--paper #fbfbfa`, `--card #ffffff`, `--soft #f2f2f3`,
`--ink #1d1d1f`, `--body #3a3a3c`, `--muted #8e8e93`, `--faint #b9b9be`,
`--line rgb(0 0 0 / .06)`, card radius 22px, grain opacity 0.

**Interface languages:** `pt_BR` (default) and `en`, through Gettext, with the
locale resolved as in leitor.

## Configuration

Environment variables, with every new one added to `mise.local.toml.example`:

| Variable | Use | Required in prod |
|---|---|---|
| `ANTHROPIC_API_KEY` | Claude enrichment | yes |
| `OPENROUTER_API_KEY` | Embeddings | yes |
| `ACERVO_ALLOWED_EMAILS` | Comma-separated registration allowlist | yes |
| `ACERVO_CHAT_MODEL` | Default `anthropic:claude-haiku-5-5` | no |
| `ACERVO_EMBEDDING_MODEL` | Default `openrouter:voyageai/voyage-4-lite` | no |
| `RESEND_API_KEY`, `MAIL_FROM` | Magic-link email | yes |
| `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST` | Standard | yes |

## Testing

**HTTP and providers**
- Extractors run against saved HTML and oEmbed fixtures through `Req.Test`, so
  CI makes no network calls.
- `SafeFetch` has unit tests for every blocked range, redirect re-checks and
  size and time limits.
- `Acervo.AI` and the `Embedder` use fakes in tests. The fake embedder hashes
  text into deterministic 1024-dimension vectors.
- A search ranking test seeds links and asserts the fused order.

**Pipeline and UI**
- Oban runs in `testing: :manual` mode. Each worker is tested with
  `perform_job/2`, and pipeline chaining with `assert_enqueued`.
- LiveView tests drive the columns, inbox and dock through element IDs.
  Tests check outcomes, not HTML strings.

**Running app:** Tidewave and screen access are used to exercise the real app
in dev for each phase.

## Phases

Each phase gets its own implementation plan, PRs, and release.

| Phase | Scope | Release |
|---|---|---|
| 1. Foundation | Remove daisyUI. Port leitor's styles, the `studio` theme, the appearance panel, fonts and components. Magic-link auth with the allowlist. Column shell and dock. Oban and pgvector extension migrations. Styler and Credo. Fly deploy on release | 0.2.0 |
| 2. Capture | URL normalization, `SafeFetch`, the extractors, image storage and serving, screenshot upload, cards, link column, manual collections | 0.3.0 |
| 3. AI | `EnrichLink`, suggestions, the inbox triage UI, editable image description and note | 0.4.0 |
| 4. Search | `EmbedLink`, the hybrid search query, search UI, the reindex task | 0.5.0 |
| 5. Mobile | Personal API tokens, the `POST /api/links` endpoint, an iOS Shortcut guide, PWA manifest and `share_target` | 0.6.0 |

## Risks

- **pgvector in production.** It must be available on the Fly Postgres.
  Verify this in phase 1, when the extension migration runs, before phase 4
  depends on it.
- **Instagram and X capture is best-effort.** They change markup and block
  crawlers often. The screenshot fallback keeps the product usable.
- **Images in the database grow backups.** At WebP sizes of 1600 px and up to
  four images per link, 10,000 links fit in a few GB. `Acervo.Storage` allows a
  move to Tigris when needed.
- **Embedding dimensions.** The 1024-dimension column assumes the model honors
  `dimensions`. `EmbedLink` asserts the length, so a mismatch fails loudly
  instead of corrupting the index.
