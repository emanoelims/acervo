# Contributing

Use Elixir `1.20.4-otp-29` and Erlang/OTP `29`, as configured in `mise.toml`.
Elixir is pinned to a specific release built for OTP 29. Erlang can receive
updates within the 29 series through `mise upgrade erlang`. Update the Elixir
pin explicitly when adopting a new release.

Run `mise install`, then `mise run setup`. Start Phoenix with `mise run dev`.
Before opening a PR, run `mise run precommit`, which executes `mix precommit`.
Mise tasks automatically use the configured tools. For individual commands,
use `mise exec -- mix <task>`. See the
[mise documentation](https://mise.jdx.dev/getting-started.html) for installation
and shell activation.

## Environment variables

`mise.toml` holds shared, non-secret defaults such as `PORT`. Secrets and
machine-specific overrides go in `mise.local.toml`, which is ignored by Git and
loaded on top of `mise.toml`. Copy `mise.local.toml.example` to start, and add
every new variable to the example with an empty value. Never commit secrets,
even temporarily: a committed credential must be revoked, not just deleted.

Production reads configuration in `config/runtime.exs` and fails to boot when
a required variable, such as `ANTHROPIC_API_KEY`, is missing.

## Branches and review

Create a branch such as `feat/search`, `fix/import`, or `docs/setup` and open a
PR against `main`. Merges use squash: the PR title becomes the commit subject on
`main`. Keep the title up to date and wait for `Conventions` and `Elixir checks`
to pass.

Use the issue forms for reproducible bugs and concrete feature proposals. PRs
should explain the resulting behavior, applicable documentation and tests, and
any database migration or authentication/authorization impact. Focus each PR on
one subject and run the nearest tests while working.

CI cancels obsolete runs, limits job runtime, pins Actions to immutable commits,
and uses caches keyed by the BEAM versions, test environment, and lockfile.
Dependabot proposes weekly Mix and GitHub Actions updates using allowed
Conventional Commit prefixes. Review its PRs and let the same required checks
validate them; updates are not merged automatically.

## Conventional Commits

Use `<type>[optional scope][!]: <description>` for commit subjects and PR titles.
Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`build`, `ci`, `chore`, and `revert`. Scopes use lowercase letters, numbers,
periods, hyphens, underscores, or slashes. Write descriptions, documentation,
and developer-facing messages in English.

Examples:

- `feat(catalog): add search`
- `fix(import): keep original file names`
- `ci: validate project conventions`
- `feat(api)!: change response format`

For incompatible changes, use `!` in the PR title and explain the migration
in the body with `BREAKING CHANGE: ...`. This preserves the signal during squash.
CI validates PR titles with `.github/scripts/check_pr_title.exs`.

## Semantic versioning

The version source is `version` in `mix.exs`, using `MAJOR.MINOR.PATCH`.

- `fix`: increment PATCH, for example `1.2.0` → `1.2.1`.
- Backward-compatible `feat`: increment MINOR, for example `1.2.0` → `1.3.0`.
- Incompatible change: increment MAJOR, for example `1.2.0` → `2.0.0`.
- Other types do not require a release by themselves; assess the public impact.

During `0.x`, the project is experimental. Our policy is to increment MINOR
for features and incompatible changes, and PATCH for fixes. The first release
with a stability commitment will be `1.0.0`.

## Changelog

`CHANGELOG.md` is curated manually for people, not generated from commits.
Add user-facing changes under `## [Unreleased]` in the same PR that makes them,
using Added, Changed, Deprecated, Removed, Fixed, and Security as applicable,
and omit empty categories. Add a Migration section when a release needs
migrations, new secrets, or manual steps. Describe the resulting behavior rather
than restating commit subjects; internal refactors and CI changes usually need
no entry.

## Releases

For a release, open a PR titled `chore(release): prepare X.Y.Z`, update
`version` in `mix.exs`, and move the `[Unreleased]` entries to a new
`## [X.Y.Z] - YYYY-MM-DD` section. After merging and passing CI on `main`,
create tag `vX.Y.Z` at the corresponding commit and publish a GitHub release
for it. CI checks that the tag matches `mix.exs` exactly. Prereleases may use
`X.Y.Z-rc.1`. Version increments are reviewed manually. Do not move or reuse
release tags.

Deployment is driven by releases: only a published, stable GitHub release
deploys to production. Pushes to `main`, tags, drafts, and prereleases do not
deploy. The deploy workflow will be added together with the production target.
This application is not published as a Hex package.

## Elixir and Phoenix

Follow `AGENTS.md`, the formatter configured in `.formatter.exs`, and official
conventions: `CamelCase` modules, `snake_case` functions and variables, predicates
ending in `?`, and functions ending in `!` for raising variants where applicable.
Use Phoenix contexts for business logic and keep it separate from the web layer.
CI requires formatting, compilation without warnings, a locked and unused-free
dependency lockfile, dependency auditing, asset builds, and passing tests.

The CI audit uses `mix hex.audit`, which fails when a locked Hex dependency has
a security advisory or was retired by its maintainers. Run
`mise exec -- mix hex.audit` separately when changing dependencies. This check
needs network access and is separate from the local `precommit` alias. When a
finding does not affect the project, acknowledge it narrowly in the `:hex`
section of `mix.exs` (`ignore_advisories` or `ignore_retirements`) and explain
why in the PR; ignored findings are still listed but no longer fail CI.

Dependabot security alerts and security updates are enabled on the repository.
They match `mix.lock` against the GitHub Advisory Database and open fix PRs
outside the weekly schedule. A clean result from either tool is not a guarantee
that every dependency is free of vulnerabilities.

## Security reports

Follow [SECURITY.md](SECURITY.md) and use the repository's private security
advisory form. Never include credentials, session cookies, tokens, or personal
data in public issues, logs, screenshots, or test fixtures.

References:

- [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
- [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
- [SemVer 2.0](https://semver.org/)
- [Elixir Version](https://hexdocs.pm/elixir/Version.html)
- [Elixir naming conventions](https://hexdocs.pm/elixir/naming-conventions.html)
- [Elixir builds in mise](https://mise.jdx.dev/lang/elixir.html)
