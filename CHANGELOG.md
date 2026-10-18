# Changelog

Versions follow [SemVer](https://semver.org/). Entries are curated manually,
following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Signing in with an allowed email creates the account; there is no separate
  sign-up screen.

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
