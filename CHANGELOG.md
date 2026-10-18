# Changelog

Versions follow [SemVer](https://semver.org/). Entries are curated manually,
following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.8.0] - 2026-10-18

AI reads every saved link and suggests where it belongs.

### Added

- Each saved link is read by AI: it gets an image description and collection suggestions in the inbox, which you accept with a click. Opus 5.5 is the default model; set `ACERVO_CHAT_MODEL` to use another.
- Triage the inbox: accept all suggestions at once, or finish a link with ✓ to dismiss the rest. Edit the image description in the link column.
- `Acervo.Release.ai_costs/0` reports the model calls and their estimated cost per day.

### Migration

- After deploying, run the enrichment backfill so links saved before this get descriptions, and inbox links get suggestions (one model call each): `fly ssh console -a acervo-app -C "/app/bin/acervo eval 'Acervo.Release.backfill_enrichment()'"`.

## [0.7.0] - 2026-10-18

Read every saved page in Acervo, even when its site blocks embedding.

### Added

- Reader mode keeps each page's article, with images, so it can be read in Acervo even when the site blocks embedding or goes offline. Pages that publish a Markdown version are read from it.

### Migration

- After deploying, run the one-off backfill so links saved before this get their article: `fly ssh console -a acervo-app -C "/app/bin/acervo eval 'Acervo.Release.backfill_reader_content()'"`.

## [0.6.0] - 2026-10-18

Read a link's page without leaving Acervo.

### Added

- Open a link's page in a new column by clicking its image; sites that can't be shown there open as a reader view.

## [0.5.0] - 2026-10-18

A calmer, more refined look.

### Changed

- Typography, spacing, columns and cards refined to match the design reference.

## [0.4.0] - 2026-10-18

Easier notes and a guide to everything Acervo does.

### Added

- Notes save with ⌘/Ctrl+Enter and confirm when saved.
- A guide to features and shortcuts, opened with ? or from the dock settings.

## [0.3.0] - 2026-10-18

Capture: save links by pasting them, see their previews and organize them.

### Added

- Links appear as cards and open in their own column with note, done and
  delete, updating live while previews are captured.
- Save links by pasting them anywhere or with the + in the dock, and organize
  them into collections you create, rename and describe.
- Add a screenshot to a link whose preview couldn't be captured, by uploading
  or pasting an image.
- Saved links are captured in the background: title, description, text and up
  to four images for web pages, YouTube, X and Instagram (best-effort), with
  retries when a site fails temporarily. Images are stored privately as WebP
  and served only to their owner.

### Changed

- Signing in with an allowed email creates the account; there is no separate
  sign-up screen.

### Security

- Outbound fetches are guarded against SSRF: private, loopback and link-local
  addresses are blocked, only ports 80 and 443 are allowed, every redirect is
  checked again, and the connection is pinned to the vetted address.
- Captured and uploaded images are re-encoded with their metadata stripped,
  and only common formats (JPEG, PNG, WebP, GIF and HEIF) are accepted.
- WebSocket frames are capped in size.

### Migration

Additive migrations create the `links`, `link_images`, `collections` and
`collection_links` tables and the `links.resolved_url` column. Images are stored
in the shared database, whose volume was extended to 10 GB. No new environment
variables; `ACERVO_ALLOWED_EMAILS` now also decides which emails can create an
account by signing in.

## [0.2.0] - 2026-10-18

First published release: the foundation of the link archive, before capture,
AI organization and search.

### Added

- Column navigation inspired by the Finder, with the inbox, all links and a
  floating dock with appearance and language settings.
- The `studio` theme (default) plus leitor's light, sepia, snow, dark and ink
  themes, four accents and four fonts, chosen per browser. The first paint
  follows a dark system theme on `auto`.
- Portuguese (default) and English interface and emails.
- Email magic-link sign-in, with registration limited to
  `ACERVO_ALLOWED_EMAILS` and sign-in links sent at most once a minute.
- Postgres 18 with `citext`, `unaccent` and `vector` (pgvector), and Oban
  background jobs.
- Fly release images deployed only from stable GitHub releases, a `/health`
  readiness check, and the deployment guide.
- Contribution, security and deployment documentation; CI validating
  Conventional Commit PR titles, release versions, formatting, Credo and tests.

### Security

- Session and remember-me cookies are `Secure` in production.
- Content Security Policy on application pages.
- Language switch redirects only to local paths.

### Migration

First deployment to `acervo-app`. Migrations create users and tokens and the
Oban tables; the `citext`, `unaccent` and `vector` extensions must already
exist in the `acervo` database, created by the cluster superuser as described
in the deployment guide. Configure the secrets listed there before publishing.
