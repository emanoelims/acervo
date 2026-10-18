# Changelog

Versions follow [SemVer](https://semver.org/). Entries are curated manually,
following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- Flash notices were invisible; they now show above the dock, with their own
  error icon.
- Logging out lands on the sign-in page instead of an access error.
- The first paint follows a dark system theme on `auto`, with no light flash.
- A failed email delivery shows an error instead of crashing registration.
- Sign-in links are sent at most once a minute per account.

### Security

- Session and remember-me cookies are `Secure` in production.
- Content Security Policy on browser pages.
- Language switch redirects are validated by Phoenix and keep the query string.

### Added

- Column navigation with the inbox, all links and a floating dock with
  appearance and language settings.
- Portuguese (default) and English interface.
- Email magic-link sign-in, with registration limited to
  `ACERVO_ALLOWED_EMAILS`.
- The `studio` theme and leitor's themes, accents and fonts, chosen per browser.
- Postgres extensions (`citext`, `unaccent`, `vector`) and Oban background
  jobs.
- Phoenix 1.8 application skeleton with PostgreSQL, LiveView, and Tailwind CSS.
- Mise-managed Elixir and Erlang versions, a shared `PORT` default of `4200`,
  and git-ignored `mise.local.toml` overrides for local secrets.
- `ANTHROPIC_API_KEY` runtime configuration, required in production.
- MIT license, contribution and security guides, issue and PR templates, and
  CI validating Conventional Commit PR titles, release versions, and Elixir checks.
