# Changelog

Versions follow [SemVer](https://semver.org/). Entries are curated manually,
following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Postgres extensions (`citext`, `unaccent`, `vector`) and Oban background
  jobs.
- Phoenix 1.8 application skeleton with PostgreSQL, LiveView, and Tailwind CSS.
- Mise-managed Elixir and Erlang versions, a shared `PORT` default of `4200`,
  and git-ignored `mise.local.toml` overrides for local secrets.
- `ANTHROPIC_API_KEY` runtime configuration, required in production.
- MIT license, contribution and security guides, issue and PR templates, and
  CI validating Conventional Commit PR titles, release versions, and Elixir checks.
