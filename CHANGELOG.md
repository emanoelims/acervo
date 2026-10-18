# Changelog

Versions follow [SemVer](https://semver.org/). Entries are curated manually,
following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
