# Phase 1 — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the generated Phoenix skeleton into acervo's foundation: leitor's
quality tooling, the database extensions and Oban, the `studio` design system
with configurable appearance, magic-link authentication restricted by an
allowlist, Portuguese and English, the empty column shell with the dock, and a
Fly deployment triggered by GitHub releases. Shipped as `0.2.0`.

**Architecture:** Port, rather than copy wholesale, the pieces of `../leitor`
that acervo needs: tokens, themes, components, hooks, auth and deploy files. Its
reading-specific CSS and modules are left behind. New code is limited to the
`studio` theme, the appearance module, the allowlist, the locale switch and the
column shell from the approved prototype.

**Tech Stack:** Elixir 1.20.4 / OTP 29, Phoenix 1.8.15, LiveView 1.2, Ecto with
Postgres 18 and pgvector 0.8.7, Oban, Tailwind v4 without daisyUI, esbuild,
Gettext, Swoosh with Resend, Fly.io.

**Spec:** `docs/superpowers/specs/2026-10-18-acervo-design.md`. Prototype:
`docs/superpowers/specs/2026-10-18-acervo-prototype.html`, option A.

## Global Constraints

- Every PR title follows Conventional Commits and is squash-merged after `Conventions` and `Elixir checks` pass. Self-merge with `gh pr merge --squash --admin --delete-branch`.
- Run `mise run precommit` before every commit. It must pass.
- New dependencies must have been released at least 7 days earlier. Check with `curl -s https://hex.pm/api/packages/<name>` and use the newest release older than 7 days.
- Pin GitHub Actions to full commit SHAs, matching `.github/workflows/ci.yml`.
- Primary keys are UUID v7 (`Ecto.UUID, autogenerate: [version: 7]`), defined through `use Acervo.Schema`.
- UI copy: little text, no repeated text, icons with `title` tooltips instead of labels. English msgids go through Gettext, and `pt_BR` is the default locale.
- Never use daisyUI classes. Never call `<.flash_group>` outside `layouts.ex`. Every key element gets a DOM id.
- User-facing changes go under `## [Unreleased]` in `CHANGELOG.md` in the same PR. New environment variables go in `mise.local.toml.example`.
- `../leitor` (`/Users/emanoelims/emanoel.dev/leitor`) is read-only reference material. Never modify it.
- Postgres runs in the `acervo-db` Apple container on `localhost:5432`. Start it with `mise run db`.

---

### Task 1: Styler and Credo

**Files:**
- Modify: `mix.exs` (deps, `aliases/0`, `cli/0`)
- Modify: `.formatter.exs`
- Modify: `.github/workflows/ci.yml` (add the Credo step)
- Modify: `CONTRIBUTING.md` (the "Elixir and Phoenix" section)

**Interfaces:**
- Produces: a `precommit` alias that runs `compile --warnings-as-errors`,
  `deps.unlock --unused`, `format`, `credo --strict` and `test`.

- [ ] **Step 1: Branch and add the dependencies**

```bash
git switch main && git pull --ff-only && git switch -c build/styler-credo
```

In `mix.exs` `deps/0`, add (check versions against the 7-day rule):

```elixir
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.12", only: [:dev, :test], runtime: false},
```

- [ ] **Step 2: Configure the formatter and the alias**

Replace `.formatter.exs` with:

```elixir
[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter, Styler],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs",
    ".github/scripts/*.exs"
  ]
]
```

In `mix.exs`, change the `precommit` alias to:

```elixir
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "credo --strict", "test"]
```

Make sure `def cli` includes `preferred_envs: [precommit: :test, credo: :test]`.

- [ ] **Step 3: Apply and fix**

Run: `mise exec -- mix deps.get && mise exec -- mix format && mise exec -- mix credo --strict`
Expected: Styler rewrites some generated files, and Credo prints
`found no issues` or a short list. Fix every Credo finding in code, not with
exclusions. Generated modules usually need a `@moduledoc` or `@moduledoc false`.

- [ ] **Step 4: Add Credo to CI**

In `.github/workflows/ci.yml`, after `- run: mix compile --warnings-as-errors`, add:

```yaml
      - run: mix credo --strict
```

In `CONTRIBUTING.md`, extend the CI sentence in "Elixir and Phoenix" so it
reads: "CI requires formatting (Styler and the HEEx formatter), compilation
without warnings, strict Credo analysis, a locked and unused-free dependency
lockfile, dependency auditing, asset builds, and passing tests."

- [ ] **Step 5: Verify and ship**

Run: `mise run precommit`. Expected: `found no issues`, then `Result: N passed`.

```bash
git add -A && git commit -m "build: add Styler and Credo"
git push -u origin build/styler-credo
gh pr create --title "build: add Styler and Credo" --body "<Change / Compatibility and data / Validation per template>"
gh pr checks --watch && gh pr merge --squash --admin --delete-branch
```

---

### Task 2: Database foundations — UUID v7 schema, extensions, Oban, pgvector

**Files:**
- Create: `lib/acervo/schema.ex`
- Create: `lib/acervo/postgrex_types.ex`
- Create: `priv/repo/migrations/<ts>_enable_extensions.exs`
- Create: `priv/repo/migrations/<ts>_add_oban.exs`
- Modify: `mix.exs` (deps), `config/config.exs`, `config/test.exs`, `lib/acervo/application.ex`
- Test: `test/acervo/database_test.exs`

**Interfaces:**
- Produces: `use Acervo.Schema`, which sets
  `@primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}`,
  `@foreign_key_type :binary_id` and `@timestamps_opts [type: :utc_datetime]`.
- Produces: the SQL function `acervo_unaccent(text) RETURNS text IMMUTABLE`.
- Produces: the extensions `citext`, `unaccent` and `vector`.
- Produces: `Acervo.PostgrexTypes`, with pgvector types registered on `Acervo.Repo`.
- Produces: Oban on `Acervo.Repo` with queues `capture: 4, ai: 2, embed: 4`,
  and `testing: :manual` in tests.

- [ ] **Step 1: Branch, add dependencies and write the failing test**

```bash
git switch main && git pull --ff-only && git switch -c build/database-foundations
```

Add to `deps/0`, after checking the 7-day rule:

```elixir
      {:oban, "~> 2.20"},
      {:pgvector, "~> 0.3"},
```

Create `test/acervo/database_test.exs`:

```elixir
defmodule Acervo.DatabaseTest do
  use Acervo.DataCase, async: true

  alias Acervo.Repo

  test "required extensions are installed" do
    %{rows: rows} = Repo.query!("SELECT extname FROM pg_extension ORDER BY extname")
    names = List.flatten(rows)

    for ext <- ~w(citext unaccent vector), do: assert(ext in names)
  end

  test "acervo_unaccent removes accents and is immutable" do
    assert %{rows: [["Cafe acucar"]]} = Repo.query!("SELECT acervo_unaccent('Café açúcar')")

    assert %{rows: [["i"]]} =
             Repo.query!("SELECT provolatile::text FROM pg_proc WHERE proname = 'acervo_unaccent'")
  end

  test "pgvector values round-trip through Postgrex" do
    %{rows: [[vector]]} = Repo.query!("SELECT '[1,2,3]'::vector")
    assert Pgvector.to_list(vector) == [1.0, 2.0, 3.0]
  end

  test "oban_jobs table exists" do
    assert %{rows: [[true]]} = Repo.query!("SELECT to_regclass('public.oban_jobs') IS NOT NULL")
  end
end
```

- [ ] **Step 2: Run the test and check that it fails**

Run: `mise exec -- mix deps.get && mise exec -- mix test test/acervo/database_test.exs`
Expected: FAIL. The extensions are missing, `acervo_unaccent` does not exist,
and the vector query does not decode.

- [ ] **Step 3: Implement**

`lib/acervo/schema.ex`:

```elixir
defmodule Acervo.Schema do
  @moduledoc """
  Shared schema defaults: UUID v7 primary keys, binary foreign keys and UTC
  second-precision timestamps.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime]
    end
  end
end
```

`lib/acervo/postgrex_types.ex`:

```elixir
Postgrex.Types.define(
  Acervo.PostgrexTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
```

In `config/config.exs`:

```elixir
config :acervo, Acervo.Repo, types: Acervo.PostgrexTypes

config :acervo, Oban,
  engine: Oban.Engines.Basic,
  repo: Acervo.Repo,
  queues: [capture: 4, ai: 2, embed: 4],
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]
```

In `config/test.exs`:

```elixir
config :acervo, Oban, testing: :manual
```

In `lib/acervo/application.ex`, add `{Oban, Application.fetch_env!(:acervo, Oban)}`
to the children list, after `Acervo.Repo`.

Generate the migrations:
- `mise exec -- mix ecto.gen.migration enable_extensions`
- `mise exec -- mix ecto.gen.migration add_oban`

Enable-extensions migration:

```elixir
defmodule Acervo.Repo.Migrations.EnableExtensions do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS citext"
    execute "CREATE EXTENSION IF NOT EXISTS unaccent"
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    # unaccent/1 is STABLE; the two-argument form with an explicit dictionary is
    # safe to wrap as IMMUTABLE so generated tsvector columns can use it.
    execute """
    CREATE FUNCTION acervo_unaccent(text) RETURNS text
      LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
      RETURN public.unaccent('public.unaccent'::regdictionary, $1)
    """
  end

  def down do
    execute "DROP FUNCTION IF EXISTS acervo_unaccent(text)"
    execute "DROP EXTENSION IF EXISTS vector"
    execute "DROP EXTENSION IF EXISTS unaccent"
    execute "DROP EXTENSION IF EXISTS citext"
  end
end
```

Oban migration:

```elixir
defmodule Acervo.Repo.Migrations.AddOban do
  use Ecto.Migration

  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down(version: 1)
end
```

- [ ] **Step 4: Migrate and run the tests**

Run: `mise exec -- mix ecto.migrate && mise exec -- mix test test/acervo/database_test.exs`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Ship**

Run `mise run precommit`. Add to `CHANGELOG.md` under `[Unreleased]` → `### Added`:
"- Postgres extensions (`citext`, `unaccent`, `vector`) and Oban background
jobs." Commit `build: add Oban, pgvector and database extensions`, then open,
check and merge the PR as in Task 1.

---

### Task 3: Design system base — tokens, themes, fonts, appearance runtime; remove daisyUI

**Files:**
- Delete: the `daisyui` dependency in `mix.exs` and `mix.lock`, and every daisyUI `@plugin` in `assets/css/app.css`
- Create: `assets/css/fonts.css`, `assets/css/tokens.css`, `assets/css/base.css`, `assets/css/components.css`
- Create: `assets/js/appearance.js`
- Create: `priv/static/fonts/*` (Inter, Schibsted Grotesk, Atkinson Hyperlegible Next, Newsreader, plus their OFL files)
- Create: `assets/vendor/lucide.js` and `assets/vendor/lucide/` (copied from leitor)
- Create: `priv/static/images/logo.svg`
- Modify: `assets/css/app.css`, `assets/js/app.js`, `lib/acervo_web/components/layouts/root.html.heex`
- Modify: `docs/superpowers/specs/2026-10-18-acervo-design.md` (the appearance line, see Step 6)

**Interfaces:**
- Produces CSS tokens on `:root`:
  - Colors and surfaces: `--paper --card --soft --ink --body --muted --faint --line --rule-strong --pill --inverse --danger`.
  - Shadows and texture: `--pop-shadow --card-shadow --grain-opacity`.
  - Accent: `--accent --accent-text`.
  - Font and motion: `--font-ui --ease`.
- Produces the `<html>` attributes `data-theme`, `data-theme-mode`,
  `data-accent` and `data-font`.
- Produces the JS exports `initializeAppearance()` and
  `setAppearance(key, value, originEl)`. The window event
  `acervo:appearance` (detail `{key, value}`) applies a change, and
  `acervo:appearance-changed` fires after each apply.
- Theme values: `auto studio light sepia snow dark ink`. Accent values:
  `vermilion cobalt moss graphite`. Font values: `inter schibsted atkinson newsreader`.
- Defaults: theme `auto` (resolves to `studio`, or to `dark` when the system
  prefers dark), accent `graphite`, font `inter`. Stored in `localStorage` key
  `acervo:appearance` as JSON.

- [ ] **Step 1: Branch and remove daisyUI**

```bash
git switch main && git pull --ff-only && git switch -c feat/design-system
```

- In `mix.exs`, delete the `{:daisyui, ...}` dependency, then run
  `mise exec -- mix deps.unlock daisyui`.
- In `assets/css/app.css`, delete both `@plugin "daisyui/..."` blocks and their
  comments.

- [ ] **Step 2: Fonts**

Copy these from leitor:

```bash
L=/Users/emanoelims/emanoel.dev/leitor
mkdir -p priv/static/fonts
cp $L/priv/static/fonts/{schibsted-grotesk,atkinson-hyperlegible-next,newsreader}-* priv/static/fonts/
```

Inter: resolve the newest version of `@fontsource-variable/inter` that is at
least 7 days old with `npm view @fontsource-variable/inter time --json`, then
download it into a fresh directory:

```bash
V=<version>; d=$(mktemp -d)
curl -fsSL -o $d/inter-latin.woff2 https://cdn.jsdelivr.net/npm/@fontsource-variable/inter@$V/files/inter-latin-wght-normal.woff2
curl -fsSL -o $d/inter-latin-ext.woff2 https://cdn.jsdelivr.net/npm/@fontsource-variable/inter@$V/files/inter-latin-ext-wght-normal.woff2
curl -fsSL -o $d/inter-OFL.txt https://raw.githubusercontent.com/rsms/inter/master/LICENSE.txt
file $d/*.woff2   # must report "Web Open Font Format (Version 2)"
cp $d/* priv/static/fonts/
```

Create `assets/css/fonts.css`:
- Copy leitor's `@font-face` blocks for Schibsted Grotesk, Atkinson
  Hyperlegible Next and Newsreader from `$L/assets/css/fonts.css`, keeping
  their `/fonts/...` URLs and `unicode-range`s.
- Add two Inter blocks:

```css
@font-face {
  font-family: 'Inter Variable';
  font-style: normal;
  font-display: swap;
  font-weight: 100 900;
  src: url(/fonts/inter-latin.woff2) format('woff2-variations');
  unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0304, U+0308, U+0329, U+2000-206F, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD;
}
@font-face {
  font-family: 'Inter Variable';
  font-style: normal;
  font-display: swap;
  font-weight: 100 900;
  src: url(/fonts/inter-latin-ext.woff2) format('woff2-variations');
  unicode-range: U+0100-02BA, U+02BD-02C5, U+02C7-02CC, U+02CE-02D7, U+02DD-02FF, U+0304, U+0308, U+0329, U+1D00-1DBF, U+1E00-1E9F, U+1EF2-1EFF, U+2020, U+20A0-20AB, U+20AD-20C0, U+2113, U+2C60-2C7F, U+A720-A7FF;
}
```

In `config/config.exs`, make sure the esbuild args include `--external:/fonts/*`
and `--external:/images/*`.

- [ ] **Step 3: Tokens and themes**

Create `assets/css/tokens.css`:
- `studio` is written out in full below.
- For `light`, `sepia`, `snow`, `dark` and `ink`, copy the hex values from
  leitor's `assets/css/gloss_reader.css` lines 9–14 (the `body { ... }` rule is
  leitor's light theme) and rename the variables as follows:
  - `--gloss-ink-2` → `--body`
  - `--gloss-ink-4` → `--faint`
  - `--gloss-rule-strong` → `--rule-strong`
  - `--gloss-pill` → `--pill`
  - `--gloss-pop-shadow` → `--pop-shadow`
  - `--gloss-card-shadow` → `--card-shadow`
  - `--gloss-grain-opacity` → `--grain-opacity`
- Keep `color-scheme`.
- Accents come from leitor's `[data-pen=...]` values in the same file:
  `--gloss-pen-light`/`-text` map to the light themes, and `-dark`/`-text` to
  `dark` and `ink`.

```css
/* Themes: studio is acervo's default (the approved prototype); the others are
   leitor's palettes with the same token names. Selected via <html data-theme>. */
:root {
  --ease: cubic-bezier(.22, 1, .36, 1);
  --danger: #b4321c;
  --font-ui: "Inter Variable", system-ui, sans-serif;
}
:root, :root[data-theme=studio] {
  --paper: #fbfbfa; --card: #ffffff; --soft: #f2f2f3;
  --ink: #1d1d1f; --body: #3a3a3c; --muted: #8e8e93; --faint: #b9b9be;
  --line: rgb(0 0 0 / .06); --rule-strong: rgb(0 0 0 / .12); --pill: #ffffff;
  --pop-shadow: 0 0 0 1px rgb(0 0 0 / .06), 0 20px 40px -12px rgb(0 0 0 / .22);
  --card-shadow: 0 0 0 1px rgb(0 0 0 / .065), 0 1px 2px rgb(0 0 0 / .03);
  --grain-opacity: 0;
  --inverse: var(--paper);
  color-scheme: light;
}
/* :root[data-theme=light] { ...leitor body values... } etc. for light, sepia, snow, dark, ink */
:root[data-theme=dark], :root[data-theme=ink] { --danger: #ffad94; }

/* Accents: light-scheme value by default, dark-scheme value under dark/ink. */
:root[data-accent=vermilion] { --accent: #c1401b; --accent-text: #a9361a; }
:root[data-accent=cobalt]    { --accent: #2c58c9; --accent-text: #234cb4; }
:root[data-accent=moss]      { --accent: #3b7a3d; --accent-text: #316934; }
:root[data-accent=graphite]  { --accent: #4b4a47; --accent-text: #3a3936; }
:is(:root[data-theme=dark], :root[data-theme=ink])[data-accent=vermilion] { --accent: #ef7a50; --accent-text: #f28b65; }
:is(:root[data-theme=dark], :root[data-theme=ink])[data-accent=cobalt]    { --accent: #86a8ff; --accent-text: #9bb7ff; }
:is(:root[data-theme=dark], :root[data-theme=ink])[data-accent=moss]      { --accent: #8fc68c; --accent-text: #a2d29f; }
:is(:root[data-theme=dark], :root[data-theme=ink])[data-accent=graphite]  { --accent: #cfc9bd; --accent-text: #ddd7cb; }

/* Fonts */
:root[data-font=inter]      { --font-ui: "Inter Variable", system-ui, sans-serif; }
:root[data-font=schibsted]  { --font-ui: "Schibsted Grotesk", system-ui, sans-serif; }
:root[data-font=atkinson]   { --font-ui: "Atkinson Hyperlegible Next", system-ui, sans-serif; }
:root[data-font=newsreader] { --font-ui: "Newsreader", Georgia, serif; }
```

Replace the comment placeholder line with the five real theme rules, written
as `:root[data-theme=X] { ... }`.

- [ ] **Step 4: Base and component styles**

Create `assets/css/base.css`:

```css
* { box-sizing: border-box; }
html, body { height: 100%; }
body {
  margin: 0; background: var(--paper); color: var(--ink);
  font-family: var(--font-ui); font-size: 15px; line-height: 1.55;
  font-feature-settings: "cv11", "ss01"; -webkit-font-smoothing: antialiased;
}
body::before {
  content: ""; position: fixed; inset: 0; pointer-events: none; z-index: 0;
  opacity: var(--grain-opacity, 0);
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='180' height='180'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='3' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0'/></filter><rect width='100%' height='100%' filter='url(%23n)'/></svg>");
}
::selection { background: color-mix(in oklab, var(--accent) 18%, transparent); color: var(--ink); }
:focus-visible { outline: 2px solid var(--rule-strong); outline-offset: 2px; }
button { font: inherit; color: inherit; }
::view-transition-old(root), ::view-transition-new(root) { animation: none; mix-blend-mode: normal; }
::view-transition { pointer-events: none; }
.theme-swap *, .theme-swap *::before, .theme-swap *::after { transition: none !important; }
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: .01ms !important; transition-duration: .01ms !important; }
}
```

Create `assets/css/components.css`:
- Copy `$L/assets/css/components.css` verbatim, then apply these renames:
  - `var(--gloss-rule-strong)` → `var(--rule-strong)`
  - `var(--gloss-ink-4)` → `var(--faint)`
- Delete the `.component-header h1,.page-heading h1,.auth-grid .hero-title`
  rule, which uses the Newsreader serif.
- Delete the `:is([data-theme=dark],[data-theme=ink]) body { --danger... }` rule,
  which now lives in `tokens.css`.
- Then append the popover rules from leitor's `app.css` that style
  `.popover`, `.popover-panel` and `.floating-panel`:
  - Find them with `grep -n "popover\|floating" $L/assets/css/app.css`.
  - Copy only the rules whose selectors start with `.popover` or `.floating`.
  - Apply the same `--gloss-*` renames, and map `--gloss-pop-shadow` →
    `--pop-shadow`.

Copy Lucide:

```bash
cp -R $L/assets/vendor/lucide $L/assets/vendor/lucide.js assets/vendor/
```

Rewrite `assets/css/app.css` to:

```css
@import "tailwindcss" source(none);
@import "./fonts.css";
@import "./tokens.css";
@import "./base.css";
@import "./components.css";
@import "phoenix-colocated/acervo/colocated.css";
@source "../css";
@source "../js";
@source "../../lib/acervo_web";
@source "../../_build/dev/phoenix-colocated/acervo/*/";
@plugin "../vendor/heroicons";
@plugin "../vendor/lucide";
@custom-variant phx-click-loading (.phx-click-loading&, .phx-click-loading &);
@custom-variant phx-submit-loading (.phx-submit-loading&, .phx-submit-loading &);
@custom-variant phx-change-loading (.phx-change-loading&, .phx-change-loading &);
@custom-variant dark (&:where([data-theme=dark], [data-theme=dark] *, [data-theme=ink], [data-theme=ink] *));
@theme { --font-sans: var(--font-ui); }
```

- [ ] **Step 5: Appearance runtime**

Create `assets/js/appearance.js`. It is adapted from leitor's `reading_theme.js`
and keeps its view-transition reveal:

```js
// Theme, accent and font are per-browser preferences (like leitor). The server
// renders the defaults on <html>, so default users never see a flash.
const KEY = 'acervo:appearance'
const OPTIONS = {
  theme: ['auto', 'studio', 'light', 'sepia', 'snow', 'dark', 'ink'],
  accent: ['vermilion', 'cobalt', 'moss', 'graphite'],
  font: ['inter', 'schibsted', 'atkinson', 'newsreader'],
}
const DEFAULTS = {theme: 'auto', accent: 'graphite', font: 'inter'}
const system = matchMedia('(prefers-color-scheme: dark)')
let state = {...DEFAULTS}
let swap = null

const resolved = theme => theme === 'auto' ? (system.matches ? 'dark' : 'studio') : theme
const read = () => {
  try {return JSON.parse(localStorage.getItem(KEY) || '{}')} catch (_) {return {}}
}
const valid = prefs => Object.fromEntries(Object.entries(DEFAULTS).map(([k, d]) =>
  [k, OPTIONS[k].includes(prefs[k]) ? prefs[k] : d]))

const apply = next => {
  state = next
  const root = document.documentElement
  root.dataset.themeMode = state.theme
  root.dataset.theme = resolved(state.theme)
  root.dataset.accent = state.accent
  root.dataset.font = state.font
  try {localStorage.setItem(KEY, JSON.stringify(state))} catch (_) {}
  window.dispatchEvent(new CustomEvent('acervo:appearance-changed', {detail: {...state}}))
}

export const appearance = () => ({...state})

export const initializeAppearance = () => {
  apply(valid(read()))
  system.addEventListener('change', () => {if (state.theme === 'auto') apply(state)})
  window.addEventListener('acervo:appearance', ({detail, target}) =>
    setAppearance(detail.key, detail.value, target?.closest?.('button')))
}

export const setAppearance = (key, value, origin) => {
  if (!OPTIONS[key]?.includes(value)) return
  const next = {...state, [key]: value}
  const root = document.documentElement
  if (key !== 'theme' || !document.startViewTransition || !origin ||
      matchMedia('(prefers-reduced-motion: reduce)').matches || resolved(value) === root.dataset.theme) {
    swap?.skipTransition()
    apply(next)
    return
  }
  const rect = origin.getBoundingClientRect(), w = innerWidth, h = innerHeight
  const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2
  const at = `${(x / w * 100).toFixed(2)}% ${(y / h * 100).toFixed(2)}%`
  const end = (Math.hypot(Math.max(x, w - x), Math.max(y, h - y)) / (Math.hypot(w, h) / Math.SQRT2) * 100).toFixed(2)
  swap?.skipTransition()
  root.classList.add('theme-swap')
  const transition = document.startViewTransition(() => apply(next))
  swap = transition
  transition.ready.then(() => root.animate(
    {clipPath: [`circle(0% at ${at})`, `circle(${end}% at ${at})`]},
    {duration: 620, easing: 'cubic-bezier(0.22, 1, 0.36, 1)', pseudoElement: '::view-transition-new(root)'}
  )).catch(() => {})
  transition.finished.finally(() => {if (swap === transition) {swap = null; root.classList.remove('theme-swap')}})
}
```

In `assets/js/app.js`, add `import {initializeAppearance} from "./appearance"`
and call `initializeAppearance()` right after the imports, before
`new LiveSocket(...)`.

In `root.html.heex`:
- Set `<html lang="pt-BR" data-theme="studio" data-theme-mode="auto" data-accent="graphite" data-font="inter">`.
  Task 6 makes `lang` dynamic.
- Set `<meta name="theme-color" content="#fbfbfa" />`.
- Add `<link rel="icon" type="image/svg+xml" href={~p"/images/logo.svg"} />`.
- Remove the generated Phoenix theme-toggle script, if it is present.

Create `priv/static/images/logo.svg`, two offset rounded cards (the acervo mark):

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect x="9" y="5" width="18" height="18" rx="5" fill="none" stroke="#1d1d1f" stroke-width="2.4" opacity=".45"/><rect x="5" y="9" width="18" height="18" rx="5" fill="#1d1d1f"/></svg>
```

Delete `priv/static/images/logo.svg`'s Phoenix predecessor if it differs, and
remove the generated `priv/static/favicon.ico` reference from the root layout.

- [ ] **Step 6: Record the first-paint decision in the spec**

In the spec's "Appearance" section, replace "Stored in `localStorage`
(`acervo:appearance`) and applied before first paint." with "Stored in
`localStorage` (`acervo:appearance`). The server renders the default appearance
on `<html>`, so default users never see a flash. Saved choices apply as soon as
`app.js` runs, without an inline script, per AGENTS.md."

- [ ] **Step 7: Verify**

Run: `mise exec -- mix assets.build`
Expected: no errors and no unresolved `@plugin`.
Run `grep -rn "daisy\|btn-\|bg-base\|text-base-content" lib assets/css`. The only
hits must be in `core_components.ex` and `layouts.ex`, which Task 4 rewrites.
Run `mise run precommit`. Expected: passing tests.
Open `http://localhost:4200`, start Tidewave and check:
- `document.documentElement.dataset` contains `theme: "studio"`.
- Running `localStorage.setItem('acervo:appearance', JSON.stringify({theme:'dark'}))`
  and reloading switches the background to `#151412`.

- [ ] **Step 8: Ship**

Add to `CHANGELOG.md` under `### Added`: "- The `studio` theme and leitor's
themes, accents and fonts, chosen per browser." Commit
`feat: add the studio design system and remove daisyUI`, then open, check and
merge the PR.

---

### Task 4: Core components and floating/select hooks

**Files:**
- Modify: `lib/acervo_web/components/core_components.ex`, replaced by a port of leitor's
- Create: `assets/js/floating.js`, `assets/js/select.js` (copied from leitor)
- Modify: `assets/js/app.js` (register the hooks)
- Test: `test/acervo_web/components/core_components_test.exs`

**Interfaces:**
- Produces:
  - `<.button>` with `variant="primary"|nil`.
  - `<.input>` with leitor's `.field` styles, covering text, email, select,
    textarea and checkbox.
  - `<.popover id= placement= >`, with a `:trigger` slot and an inner panel.
  - `<.dropdown_item>`.
  - `<.flash>`.
  - `<.icon name="hero-*"|"lucide-*"|"acervo-mark">`.
  - `show/2`, `hide/2` and `translate_error/1`.
- Produces: the `Floating` and `Select` hooks, registered in `app.js`.

- [ ] **Step 1: Branch and write the failing component test**

```bash
git switch main && git pull --ff-only && git switch -c feat/core-components
```

`test/acervo_web/components/core_components_test.exs`:

```elixir
defmodule AcervoWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias AcervoWeb.CoreComponents

  test "button uses leitor's action classes" do
    assigns = %{}
    html = rendered_to_string(~H|<CoreComponents.button variant="primary">Go</CoreComponents.button>|)
    doc = LazyHTML.from_fragment(html)
    assert LazyHTML.filter(doc, "button.action.action-primary") |> Enum.count() == 1
  end

  test "popover renders a floating details element with a trigger" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.popover id="p">
        <:trigger>Open</:trigger>
        Panel
      </CoreComponents.popover>
      """)

    doc = LazyHTML.from_fragment(html)
    assert LazyHTML.filter(doc, "details#p[phx-hook=Floating] .popover-panel") |> Enum.count() == 1
  end

  test "acervo-mark icon renders the inline logo" do
    html = render_component(&CoreComponents.icon/1, name: "acervo-mark")
    assert LazyHTML.filter(LazyHTML.from_fragment(html), "svg.acervo-mark") |> Enum.count() == 1
  end
end
```

- [ ] **Step 2: Run and confirm failure**

Run: `mise exec -- mix test test/acervo_web/components/core_components_test.exs`
Expected: FAIL. The generated core components have no `variant` with those
classes, no `popover`, and no `acervo-mark`.

- [ ] **Step 3: Port the components**

1. Copy `$L/lib/leitor_web/components/core_components.ex` over
   `lib/acervo_web/components/core_components.ex`, then rename:
   `sed -i '' 's/LeitorWeb/AcervoWeb/g; s/Leitor\./Acervo./g; s/leitor/acervo/g'`.
2. Replace the `icon(%{name: "leitor-mark"})` clause with:

```elixir
  def icon(%{name: "acervo-mark"} = assigns) do
    ~H"""
    <svg class={["acervo-mark", @class]} viewBox="0 0 32 32" aria-hidden="true">
      <rect x="9" y="5" width="18" height="18" rx="5" fill="none" stroke="currentColor" stroke-width="2.4" opacity=".45" />
      <rect x="5" y="9" width="18" height="18" rx="5" fill="currentColor" />
    </svg>
    """
  end
```

3. Delete `header/1`, `table/1` and `list/1` if nothing in `lib/` uses them
   (`grep -rn "<.table\|<.header\|<.list" lib`). Keep them if generated code
   does.
4. Copy the hooks: `cp $L/assets/js/floating.js $L/assets/js/select.js assets/js/`.
   Grep them for `leitor` and rename any event names to `acervo`.
5. In `app.js`, add
   `import {Floating} from "./floating"` and `import {Select} from "./select"`,
   then `hooks: {...colocatedHooks, Floating, Select}`.
6. If `floating.js` imports `@floating-ui/dom`, check `$L/assets/package.json`,
   create `assets/package.json` with the same `@floating-ui/dom` version, run
   `npm install --prefix assets`, commit `assets/package-lock.json`, and add to
   `assets.setup` the step `cmd npm ci --prefix assets --ignore-scripts`. Also
   add `- run: npm ci --prefix assets --ignore-scripts` before the CI
   `mix assets.setup` step.

- [ ] **Step 4: Fix call sites and run the tests**

Update `layouts.ex` and any generated templates that use removed attributes
or daisyUI classes. Task 7 rewrites the layout anyway, so keep the edits here
minimal: it only needs to compile.
Run: `mise exec -- mix test test/acervo_web/components/core_components_test.exs && mise run precommit`
Expected: PASS.

- [ ] **Step 5: Ship**

Commit `feat: port leitor's core components and floating hooks`, then open,
check and merge the PR. No CHANGELOG entry is needed (internal).

---

### Task 5: Magic-link authentication restricted by an allowlist

**Files:**
- Generate: `mix phx.gen.auth Accounts User users --live`, which creates
  `lib/acervo/accounts*`, `lib/acervo_web/user_auth.ex`,
  `lib/acervo_web/live/user_live/*`,
  `lib/acervo_web/controllers/user_session_controller.ex`, a migration and tests.
- Create: `lib/acervo/accounts/allowlist.ex`, `assets/css/auth.css`
- Modify: `config/runtime.exs`, `config/dev.exs`, `config/test.exs`, `mise.local.toml.example`
- Test: `test/acervo/accounts/allowlist_test.exs`, plus the generated tests adjusted

**Interfaces:**
- Consumes: `use Acervo.Schema` (Task 2), `citext` (Task 2), and the components (Task 4).
- Produces: `Acervo.Accounts.Scope` (`%Scope{user: %User{}}`) and
  `AcervoWeb.UserAuth` with `on_mount :require_authenticated` and
  `:mount_current_scope`.
- Produces: `live_session :require_authenticated_user` in the router, which
  Task 7 mounts its routes in.
- Produces: `Acervo.Accounts.Allowlist.allowed?(email) :: boolean` and
  `Allowlist.parse(String.t() | nil) :: [String.t()]`.
- Produces the config `:acervo, :allowed_emails`: `:all` (dev and test default)
  or a list of downcased emails.

- [ ] **Step 1: Branch and generate**

```bash
git switch main && git pull --ff-only && git switch -c feat/magic-link-auth
mise exec -- mix phx.gen.auth Accounts User users --live
mise exec -- mix deps.get
```

When it asks about the hashing library, accept the default. Step 3 removes it.

- [ ] **Step 2: Write the allowlist tests**

`test/acervo/accounts/allowlist_test.exs`:

```elixir
defmodule Acervo.Accounts.AllowlistTest do
  use ExUnit.Case, async: false

  alias Acervo.Accounts.Allowlist

  setup do
    previous = Application.get_env(:acervo, :allowed_emails)
    on_exit(fn -> Application.put_env(:acervo, :allowed_emails, previous) end)
  end

  test "parse/1 trims, downcases and drops blanks" do
    assert Allowlist.parse(" Me@Example.com, ,other@x.io ") == ["me@example.com", "other@x.io"]
    assert Allowlist.parse(nil) == []
  end

  test "allowed?/1 accepts anyone when configured as :all" do
    Application.put_env(:acervo, :allowed_emails, :all)
    assert Allowlist.allowed?("anyone@example.com")
  end

  test "allowed?/1 matches case-insensitively against the list" do
    Application.put_env(:acervo, :allowed_emails, ["me@example.com"])
    assert Allowlist.allowed?(" ME@example.com ")
    refute Allowlist.allowed?("other@example.com")
  end
end
```

Then add a registration test to the generated
`test/acervo/accounts_test.exs`, inside `describe "register_user/1"`:

```elixir
    test "rejects emails outside the allowlist" do
      Application.put_env(:acervo, :allowed_emails, ["owner@example.com"])
      on_exit(fn -> Application.put_env(:acervo, :allowed_emails, :all) end)

      assert {:error, changeset} = Accounts.register_user(%{email: "stranger@example.com"})
      assert "is not allowed to register" in errors_on(changeset).email
    end
```

Run: `mise exec -- mix test test/acervo/accounts/allowlist_test.exs`
Expected: FAIL (`Allowlist` is undefined).

- [ ] **Step 3: Implement the allowlist and make the app magic-link only**

`lib/acervo/accounts/allowlist.ex`:

```elixir
defmodule Acervo.Accounts.Allowlist do
  @moduledoc """
  Restricts registration to configured emails. `:all` (dev and test default)
  allows anyone; production requires `ACERVO_ALLOWED_EMAILS`.
  """

  @spec allowed?(String.t()) :: boolean()
  def allowed?(email) when is_binary(email) do
    case Application.get_env(:acervo, :allowed_emails, :all) do
      :all -> true
      emails when is_list(emails) -> normalize(email) in emails
    end
  end

  @spec parse(String.t() | nil) :: [String.t()]
  def parse(nil), do: []

  def parse(value) when is_binary(value) do
    value |> String.split(",") |> Enum.map(&normalize/1) |> Enum.reject(&(&1 == ""))
  end

  defp normalize(email), do: email |> String.trim() |> String.downcase()
end
```

In `User.email_changeset/3`, after the existing email validations, add a
registration-only check. Pass `validate_allowlist: true` from
`Accounts.register_user/1`:

```elixir
    |> maybe_validate_allowlist(opts)
```

```elixir
  defp maybe_validate_allowlist(changeset, opts) do
    if Keyword.get(opts, :validate_allowlist, false) do
      validate_change(changeset, :email, fn :email, email ->
        if Acervo.Accounts.Allowlist.allowed?(email), do: [], else: [email: "is not allowed to register"]
      end)
    else
      changeset
    end
  end
```

Configuration:
- In `config/config.exs`, add `config :acervo, :allowed_emails, :all`.
- In `config/runtime.exs`, add this before the `if config_env() == :prod`
  block:

```elixir
if allowed = System.get_env("ACERVO_ALLOWED_EMAILS") do
  emails =
    allowed |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.downcase())) |> Enum.reject(&(&1 == ""))

  config :acervo, :allowed_emails, emails
end
```

- Inside the prod block, add:

```elixir
  System.get_env("ACERVO_ALLOWED_EMAILS") ||
    raise "environment variable ACERVO_ALLOWED_EMAILS is missing (comma-separated emails allowed to register)"
```

- Add `# ACERVO_ALLOWED_EMAILS = ""` to `mise.local.toml.example`, with the
  comment `# Optional in dev; required in production`.

Make it magic-link only. Leitor removed browser password login; acervo has no
legacy accounts, so it removes passwords entirely:
- Remove the password form and fields from `user_live/login.ex`, keeping the
  magic-link form.
- Remove the password section from `user_live/settings.ex`.
- Remove the password create clause from `UserSessionController`.
- Remove these from `Accounts`: `get_user_by_email_and_password/2`,
  `change_user_password/3`, `update_user_password/2`, and the password paths
  in `sudo_mode?`, if any.
- Remove these from `User`: `password_changeset/3`, `valid_password?/2`, the
  `:password` and `:hashed_password` fields, and their migration column.
- Remove the hashing dependency (`bcrypt_elixir` or `argon2_elixir`) and its
  config in `config/test.exs`.
- Delete or adjust the generated tests for the removed functions.
  `grep -rn "password" lib test` must return nothing except the
  `password-less` copy.

Switch `User` to `use Acervo.Schema`, replacing the generated
`@primary_key`/`@foreign_key_type`. Do the same for `UserToken`.

Mailer: copy leitor's production Swoosh config:
- `grep -n "Resend\|mail_from\|api_client" $L/config/*.exs`.
- Configure `Acervo.Mailer` with `Swoosh.Adapters.Resend` (`RESEND_API_KEY`).
- Add `config :swoosh, :api_client, Swoosh.ApiClient.Req` in `prod.exs`.
- Add `:mail_from` from `MAIL_FROM`; both variables raise if missing in prod.
- Make `UserNotifier` send from `{"Acervo", Application.fetch_env!(:acervo, :mail_from)}`,
  with `"contato@localhost"` as the dev/test default in `config.exs`.

Styles: copy `$L/assets/css/auth.css` to `assets/css/auth.css`, rename
`--gloss-*` per Task 3, and import it in `app.css`. Apply its classes in the
generated login, registration and confirmation LiveViews so they use leitor's
centered card layout, and use `<.icon name="acervo-mark" class="size-8" />`
as the logo.

- [ ] **Step 4: Migrate and run all tests**

Run: `mise exec -- mix ecto.migrate && mise run precommit`
Expected: all tests pass, including the allowlist tests and the new
`register_user` case. Check that `grep -rn "password" lib` is empty.

- [ ] **Step 5: Exercise the flow**

- Open `/users/register`, register `owner@example.com`, then open
  `/dev/mailbox` and follow the magic link.
- Expected: you land on `/`, signed in.
- Sign out, set `ACERVO_ALLOWED_EMAILS=owner@example.com` in
  `mise.local.toml`, restart, and try registering another email.
- Expected: "is not allowed to register".

- [ ] **Step 6: Ship**

Add to `CHANGELOG.md` `### Added`: "- Email magic-link sign-in, with
registration limited to `ACERVO_ALLOWED_EMAILS`." Commit
`feat: add magic-link authentication with an allowlist`, then open, check and
merge the PR.

---

### Task 6: Portuguese and English with a locale switch

**Files:**
- Create: `lib/acervo_web/locale.ex`, `lib/acervo_web/controllers/locale_controller.ex`
- Create: `priv/gettext/pt_BR/LC_MESSAGES/default.po`, `priv/gettext/pt_BR/LC_MESSAGES/errors.po`
- Modify: `lib/acervo_web/router.ex` (the `:browser` pipeline, the route, and the `on_mount` of both auth live_sessions), `root.html.heex` (`lang`), `config/config.exs` (`default_locale`)
- Test: `test/acervo_web/locale_test.exs`

**Interfaces:**
- Produces: the `AcervoWeb.Locale` plug and `on_mount(:default, ...)`, plus
  `Locale.locales/0` (`["pt_BR", "en"]`) and `Locale.normalize/1`.
- Produces: the `GET /locale/:locale` route (`?return_to=/path`), which sets
  the `acervo_locale` cookie for a year and redirects.
- Produces: the `@locale` assign in conns and sockets.

- [ ] **Step 1: Branch and write the failing tests**

```bash
git switch main && git pull --ff-only && git switch -c feat/locales
```

`test/acervo_web/locale_test.exs`:

```elixir
defmodule AcervoWeb.LocaleTest do
  use AcervoWeb.ConnCase, async: true

  alias AcervoWeb.Locale

  test "normalize/1 falls back to pt_BR" do
    assert Locale.normalize("en") == "en"
    assert Locale.normalize("xx") == "pt_BR"
    assert Locale.normalize(nil) == "pt_BR"
  end

  test "defaults to Portuguese", %{conn: conn} do
    conn = get(conn, ~p"/users/log-in")
    assert conn.assigns.locale == "pt_BR"
    assert html_response(conn, 200) =~ ~s(lang="pt-BR")
  end

  test "switching sets a cookie and redirects to a local path", %{conn: conn} do
    conn = get(conn, ~p"/locale/en?return_to=/users/log-in")
    assert redirected_to(conn) == "/users/log-in"
    assert conn.resp_cookies["acervo_locale"].value == "en"
  end

  test "ignores external return paths", %{conn: conn} do
    conn = get(conn, ~p"/locale/en?return_to=//evil.example")
    assert redirected_to(conn) == "/"
  end

  test "the cookie selects English", %{conn: conn} do
    conn = conn |> put_req_cookie("acervo_locale", "en") |> get(~p"/users/log-in")
    assert conn.assigns.locale == "en"
    assert html_response(conn, 200) =~ ~s(lang="en")
  end
end
```

Run: `mise exec -- mix test test/acervo_web/locale_test.exs`
Expected: FAIL (`AcervoWeb.Locale` is undefined).

- [ ] **Step 2: Implement**

`lib/acervo_web/locale.ex`:

```elixir
defmodule AcervoWeb.Locale do
  @moduledoc """
  Resolves the interface locale from the `acervo_locale` cookie (default
  `pt_BR`) for controllers and LiveViews.
  """
  import Plug.Conn

  @locales ~w(pt_BR en)
  @default "pt_BR"
  @cookie "acervo_locale"

  def locales, do: @locales
  def cookie, do: @cookie

  def normalize(locale) when locale in @locales, do: locale
  def normalize(_), do: @default

  def html_lang("pt_BR"), do: "pt-BR"
  def html_lang(locale), do: locale

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    locale = normalize(conn.cookies[@cookie])
    Gettext.put_locale(AcervoWeb.Gettext, locale)
    conn |> put_session(:locale, locale) |> assign(:locale, locale)
  end

  def on_mount(:default, _params, session, socket) do
    locale = normalize(session["locale"])
    Gettext.put_locale(AcervoWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end
end
```

`lib/acervo_web/controllers/locale_controller.ex`:

```elixir
defmodule AcervoWeb.LocaleController do
  use AcervoWeb, :controller

  alias AcervoWeb.Locale

  def update(conn, %{"locale" => locale} = params) do
    conn
    |> put_resp_cookie(Locale.cookie(), Locale.normalize(locale), max_age: 60 * 60 * 24 * 365, same_site: "Lax")
    |> redirect(to: safe_path(params["return_to"]))
  end

  # Only same-origin absolute paths: rejects "//host", backslashes and newlines.
  defp safe_path("/" <> _ = path) do
    if String.starts_with?(path, "//") or String.contains?(path, ["\\", "\n", "\r"]), do: "/", else: path
  end

  defp safe_path(_), do: "/"
end
```

Router:
- Add `plug AcervoWeb.Locale` to the `:browser` pipeline, after
  `fetch_live_flash`.
- Add `get "/locale/:locale", LocaleController, :update` in the public
  `scope "/"`.
- Add `AcervoWeb.Locale` to the `on_mount` list of both generated auth
  `live_session`s, after the `UserAuth` entry.

In `root.html.heex`, use `<html lang={AcervoWeb.Locale.html_lang(assigns[:locale] || "pt_BR")} ...>`.

In `config/config.exs`, add `config :acervo, AcervoWeb.Gettext, default_locale: "pt_BR", locales: ~w(pt_BR en)`.

- [ ] **Step 3: Extract and translate**

Run: `mise exec -- mix gettext.extract && mise exec -- mix gettext.merge priv/gettext --locale pt_BR`
Then fill in every `msgstr` in `priv/gettext/pt_BR/LC_MESSAGES/default.po` and
`errors.po` with natural Brazilian Portuguese, keeping the interface's terse
tone. Use `"Caixa de entrada"`, `"Tudo"`, `"Entrar"`, `"Sair"`,
`"Enviar link de acesso"`, `"Aparência"` and `"Idioma"`. For `"is not allowed to register"`,
use `"não está autorizado a se cadastrar"`. Leave no empty `msgstr`:
`grep -c 'msgstr ""$' priv/gettext/pt_BR/LC_MESSAGES/*.po` should return 1
(the header) per file.

- [ ] **Step 4: Run tests and ship**

Run: `mise exec -- mix test test/acervo_web/locale_test.exs && mise run precommit`
Expected: PASS. Add to `CHANGELOG.md` `### Added`: "- Portuguese (default) and
English interface." Commit `feat: add Portuguese and English with a locale switch`, then
open, check and merge the PR.

---

### Task 7: Column shell, dock and appearance panel

**Files:**
- Create: `lib/acervo_web/live/archive_live.ex`
- Create: `lib/acervo_web/components/archive_components.ex`
- Create: `assets/css/archive.css`
- Modify: `lib/acervo_web/components/layouts.ex` (`app/1` becomes the columns frame, with the flash group)
- Modify: `lib/acervo_web/router.ex` (live routes; delete `PageController`'s route)
- Delete: `lib/acervo_web/controllers/page_controller.ex`, `page_html.ex`, `page_html/`, and their test
- Test: `test/acervo_web/live/archive_live_test.exs`

**Interfaces:**
- Consumes: `UserAuth` and `live_session :require_authenticated_user` (Task 5),
  `AcervoWeb.Locale` (Task 6), `<.popover>`, `<.icon>` and `<.dropdown_item>`
  (Task 4), and the window event `acervo:appearance` (Task 3).
- Produces these routes: `live "/", ArchiveLive, :home`,
  `live "/inbox", ArchiveLive, :inbox` and `live "/all", ArchiveLive, :all`.
- Produces these components in `AcervoWeb.ArchiveComponents`:
  - `column/1`, with attrs `id`, `title` (optional) and `class`, slots
    `inner_block` and `actions`, plus the ↑ pill via the colocated hook
    `.ColumnScroll`.
  - `nav_item/1`, with attrs `id`, `navigate`, `active`, `count` and `dot`, and
    an `inner_block` slot.
  - `dock/1`, with attrs `active` (`:home | :inbox`) and `inbox_count`.
  - `appearance_panel/1`.
  - `empty/1`.
- Produces these DOM ids: `#columns`, `#column-root`, `#nav-inbox`,
  `#nav-all`, `#column-inbox`, `#column-all`, `#dock`, `#dock-home`,
  `#dock-inbox`, `#dock-settings`, `#appearance-panel`, `#theme-option-<t>`,
  `#accent-option-<a>`, `#font-option-<f>`, `#locale-option-<l>` and
  `#dock-log-out`.
- Later phases put real collections and links into these columns. Phase 1
  shows zero counts and empty states.

- [ ] **Step 1: Branch and write the failing LiveView tests**

```bash
git switch main && git pull --ff-only && git switch -c feat/column-shell
```

`test/acervo_web/live/archive_live_test.exs`:

```elixir
defmodule AcervoWeb.ArchiveLiveTest do
  use AcervoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "redirects visitors to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/")
  end

  describe "signed in" do
    setup :register_and_log_in_user

    test "home shows the root column and the dock", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#columns #column-root")
      assert has_element?(view, "#nav-inbox")
      assert has_element?(view, "#nav-all")
      assert has_element?(view, "#dock #dock-home[aria-current=page]")
      refute has_element?(view, "#column-inbox")
    end

    test "inbox opens a second column with an empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inbox")
      assert has_element?(view, "#column-inbox .empty")
      assert has_element?(view, "#nav-inbox[aria-current=page]")
      assert has_element?(view, "#dock-inbox[aria-current=page]")
    end

    test "navigating from the nav patches to /all", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#nav-all") |> render_click()
      assert_patch(view, ~p"/all")
      assert has_element?(view, "#column-all")
    end

    test "settings exposes appearance, language and log out", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#appearance-panel #theme-option-studio")
      assert has_element?(view, "#appearance-panel #accent-option-graphite")
      assert has_element?(view, "#appearance-panel #font-option-inter")
      assert has_element?(view, "#locale-option-en[href^='/locale/en']")
      assert has_element?(view, "#dock-log-out")
    end
  end
end
```

Run: `mise exec -- mix test test/acervo_web/live/archive_live_test.exs`
Expected: FAIL (no route or LiveView).

- [ ] **Step 2: Layout and components**

In `Layouts.app/1`:
- Render the frame `<div id="app" class="app-frame">`.
- Inside it, render `{render_slot(@inner_block)}` and `<.flash_group flash={@flash} />`.
- Keep the attrs `flash` and `current_scope`.
- Delete the generated Phoenix navbar and theme toggle.

`lib/acervo_web/components/archive_components.ex`:

```elixir
defmodule AcervoWeb.ArchiveComponents do
  @moduledoc "Columns, navigation and the floating dock (approved prototype, option A)."
  use AcervoWeb, :html

  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :class, :string, default: nil
  slot :actions
  slot :inner_block, required: true

  def column(assigns) do
    ~H"""
    <section id={@id} class={["column", @class]}>
      <button :if={@title} type="button" class="column-up" data-column-up title={@title}>
        <.icon name="lucide-arrow-up" class="size-3.5" /><span>{@title}</span>
      </button>
      <div class="column-scroll" id={"#{@id}-scroll"} phx-hook=".ColumnScroll">
        <header :if={@title} class="column-head">
          <h2><span class="column-title">{@title}</span><span class="chev">›</span></h2>
          {render_slot(@actions)}
        </header>
        {render_slot(@inner_block)}
      </div>
    </section>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ColumnScroll">
      export default {
        mounted() {
          this.pill = this.el.parentElement.querySelector('[data-column-up]')
          this.onScroll = () => this.pill?.classList.toggle('is-shown', this.el.scrollTop > 150)
          this.el.addEventListener('scroll', this.onScroll, {passive: true})
          this.pill?.addEventListener('click', () => this.el.scrollTo({top: 0, behavior: 'smooth'}))
          this.el.closest('.columns')?.scrollTo({left: 1e6, behavior: 'smooth'})
        },
        destroyed() { this.el.removeEventListener('scroll', this.onScroll) }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  attr :count, :integer, default: nil
  attr :dot, :boolean, default: false
  slot :inner_block, required: true

  def nav_item(assigns) do
    ~H"""
    <li>
      <.link id={@id} patch={@navigate} class={["nav-item", @active && "is-active"]} aria-current={@active && "page"}>
        {render_slot(@inner_block)}
        <span :if={@dot} class="nav-dot" aria-hidden="true"></span>
        <span :if={@count} class="nav-count">{@count}</span>
      </.link>
    </li>
    """
  end

  slot :inner_block, required: true

  def empty(assigns) do
    ~H"""
    <p class="empty">{render_slot(@inner_block)}</p>
    """
  end

  attr :active, :atom, values: [:home, :inbox], required: true
  attr :inbox_count, :integer, default: 0
  attr :locale, :string, required: true
  attr :return_to, :string, required: true

  def dock(assigns) do
    ~H"""
    <nav id="dock" class="dock" aria-label={gettext("Navigation")}>
      <.link id="dock-home" patch={~p"/"} class={["dock-item", @active == :home && "is-active"]} aria-current={@active == :home && "page"} title="Acervo">
        <.icon name="lucide-house" class="size-[18px]" /><span class="dock-label">Acervo</span>
      </.link>
      <.link id="dock-inbox" patch={~p"/inbox"} class={["dock-item", @active == :inbox && "is-active"]} aria-current={@active == :inbox && "page"} title={gettext("Inbox")}>
        <.icon name="lucide-inbox" class="size-[18px]" /><span class="dock-label">{gettext("Inbox")}</span>
        <span :if={@inbox_count > 0} class="dock-badge" aria-hidden="true"></span>
      </.link>
      <.popover id="dock-settings" placement="top" class="dock-popover">
        <:trigger><span class="dock-item" title={gettext("Settings")}><.icon name="lucide-settings-2" class="size-[18px]" /></span></:trigger>
        <.appearance_panel locale={@locale} return_to={@return_to} />
        <div class="dropdown-divider"></div>
        <.link id="dock-log-out" href={~p"/users/log-out"} method="delete" class="dropdown-item">
          <.icon name="lucide-log-out" class="size-4" /><span class="dropdown-item-label">{gettext("Log out")}</span>
        </.link>
      </.popover>
    </nav>
    """
  end

  attr :locale, :string, required: true
  attr :return_to, :string, required: true

  def appearance_panel(assigns) do
    assigns =
      assign(assigns,
        themes: ~w(auto studio light sepia snow dark ink),
        accents: ~w(vermilion cobalt moss graphite),
        fonts: [{"inter", "Inter"}, {"schibsted", "Schibsted"}, {"atkinson", "Atkinson"}, {"newsreader", "Newsreader"}]
      )

    ~H"""
    <div id="appearance-panel" class="appearance" phx-hook=".Appearance">
      <div class="appearance-row" role="group" aria-label={gettext("Theme")}>
        <button :for={t <- @themes} id={"theme-option-#{t}"} type="button" class={["swatch", "swatch-#{t}"]}
          data-appearance="theme" data-value={t} title={t}
          phx-click={JS.dispatch("acervo:appearance", detail: %{key: "theme", value: t})}></button>
      </div>
      <div class="appearance-row" role="group" aria-label={gettext("Accent")}>
        <button :for={a <- @accents} id={"accent-option-#{a}"} type="button" class={["dot", "dot-#{a}"]}
          data-appearance="accent" data-value={a} title={a}
          phx-click={JS.dispatch("acervo:appearance", detail: %{key: "accent", value: a})}></button>
      </div>
      <div class="appearance-row appearance-fonts" role="group" aria-label={gettext("Font")}>
        <button :for={{f, label} <- @fonts} id={"font-option-#{f}"} type="button" class={["font-chip", "font-#{f}"]}
          data-appearance="font" data-value={f} title={label}
          phx-click={JS.dispatch("acervo:appearance", detail: %{key: "font", value: f})}>Aa</button>
      </div>
      <div class="appearance-row" role="group" aria-label={gettext("Language")}>
        <.link :for={l <- AcervoWeb.Locale.locales()} id={"locale-option-#{l}"}
          href={~p"/locale/#{l}?#{[return_to: @return_to]}"} class={["lang-chip", @locale == l && "is-active"]}>
          {if l == "pt_BR", do: "PT", else: "EN"}
        </.link>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Appearance">
      export default {
        mounted() { this.sync = () => this.syncButtons(); window.addEventListener('acervo:appearance-changed', this.sync); this.sync() },
        updated() { this.sync() },
        destroyed() { window.removeEventListener('acervo:appearance-changed', this.sync) },
        syncButtons() {
          const d = document.documentElement.dataset
          const current = {theme: d.themeMode, accent: d.accent, font: d.font}
          this.el.querySelectorAll('[data-appearance]').forEach(b =>
            b.setAttribute('aria-pressed', String(current[b.dataset.appearance] === b.dataset.value)))
        }
      }
    </script>
    """
  end
end
```

If `lucide-house`, `lucide-inbox`, `lucide-settings-2`, `lucide-log-out` or
`lucide-arrow-up` is missing from `assets/vendor/lucide`, list the folder and
pick the nearest existing name.

Import `AcervoWeb.ArchiveComponents` in the `html_helpers` of `acervo_web.ex`.

- [ ] **Step 3: ArchiveLive**

`lib/acervo_web/live/archive_live.ex`:

```elixir
defmodule AcervoWeb.ArchiveLive do
  @moduledoc "The column browser: root navigation plus the selected section."
  use AcervoWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, inbox_count: 0, total_count: 0, collections_count: 0)}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, return_to: URI.parse(uri).path, page_title: title(socket.assigns.live_action))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="columns" class="columns">
        <.column id="column-root" class="column-root">
          <h1 class="root-title">Acervo</h1>
          <p class="lead">
            {gettext("Good things I find on the internet.")}
            {ngettext("One link", "%{count} links", @total_count)} · {ngettext("one collection", "%{count} collections", @collections_count)}.
          </p>
          <ul class="nav">
            <.nav_item id="nav-inbox" navigate={~p"/inbox"} active={@live_action == :inbox} dot={@inbox_count > 0} count={@inbox_count}>
              {gettext("Inbox")}
            </.nav_item>
            <.nav_item id="nav-all" navigate={~p"/all"} active={@live_action == :all} count={@total_count}>
              {gettext("All")}
            </.nav_item>
          </ul>
        </.column>

        <.column :if={@live_action == :inbox} id="column-inbox" title={gettext("Inbox")}>
          <.empty>{gettext("Nothing waiting.")}</.empty>
        </.column>

        <.column :if={@live_action == :all} id="column-all" title={gettext("All")}>
          <.empty>{gettext("Nothing saved yet.")}</.empty>
        </.column>
      </div>
      <.dock active={if @live_action == :inbox, do: :inbox, else: :home} inbox_count={@inbox_count} locale={@locale} return_to={@return_to} />
    </Layouts.app>
    """
  end

  defp title(:inbox), do: gettext("Inbox")
  defp title(:all), do: gettext("All")
  defp title(_), do: "Acervo"
end
```

Router, inside the generated `live_session :require_authenticated_user` scope:

```elixir
      live "/", ArchiveLive, :home
      live "/inbox", ArchiveLive, :inbox
      live "/all", ArchiveLive, :all
```

Then remove `get "/", PageController, :home` and delete the `PageController`
files and their test. Make sure `UserAuth`'s signed-in path is `~p"/"`.

- [ ] **Step 4: Styles**

`assets/css/archive.css`, imported in `app.css`. It follows the prototype's
values, translated to tokens:

```css
.app-frame { position: relative; height: 100vh; overflow: hidden; }
.columns { display: flex; height: 100%; overflow-x: auto; overflow-y: hidden; scroll-behavior: smooth; scrollbar-width: none; }
.columns::-webkit-scrollbar { display: none; }
.column { position: relative; flex: 0 0 max(340px, calc(100vw / 3)); height: 100%; border-right: 1px solid var(--line); }
.column:last-child { border-right: 0; }
.column-scroll { height: 100%; overflow-y: auto; padding: 46px 40px 140px; scrollbar-width: thin; scrollbar-color: var(--rule-strong) transparent; animation: column-in .55s var(--ease) both; }
.column-root .column-scroll { animation: none; }
@keyframes column-in { from { opacity: 0; transform: translateX(18px); } to { opacity: 1; transform: none; } }
.column-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 22px; }
.column-head h2 { display: flex; align-items: center; gap: 8px; min-width: 0; margin: 0; font-size: 28px; font-weight: 600; letter-spacing: -.025em; line-height: 1.12; }
.column-title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.chev { flex: none; color: var(--faint); font-weight: 400; font-size: 24px; }
.column-up { position: absolute; top: 16px; left: 50%; z-index: 5; display: flex; align-items: center; gap: 6px; max-width: 80%; padding: 8px 14px; border: 0; border-radius: 999px; background: color-mix(in oklab, var(--card) 85%, transparent); backdrop-filter: blur(14px); box-shadow: var(--pop-shadow); font-size: 14px; white-space: nowrap; cursor: pointer; opacity: 0; pointer-events: none; transform: translate(-50%, -14px); transition: all .35s var(--ease); }
.column-up.is-shown { opacity: 1; pointer-events: auto; transform: translate(-50%, 0); }
.root-title { margin: 0 0 24px; font-size: 30px; font-weight: 600; letter-spacing: -.025em; line-height: 1.12; }
.lead { margin: 0; color: var(--body); font-size: 16.5px; line-height: 1.62; }
.nav { margin: 46px 0 0; padding: 0; list-style: none; }
.nav-item { display: flex; align-items: center; gap: 10px; padding: 9px 0; color: var(--muted); font-size: 17px; text-decoration: none; transition: color .2s; }
.nav-item:hover, .nav-item.is-active { color: var(--ink); }
.nav-item.is-active { font-weight: 500; }
.nav-item.is-active::before { content: ""; width: 3px; height: 19px; margin: 0 -3px 0 -14px; border-radius: 2px; background: var(--ink); }
.nav-count { margin-left: auto; color: var(--faint); font-size: 13px; font-variant-numeric: tabular-nums; font-weight: 400; }
.nav-dot { width: 7px; height: 7px; border-radius: 50%; background: #f2b84b; }
.empty { color: var(--muted); font-size: 15px; line-height: 1.6; }
.dock { position: fixed; left: 50%; bottom: 24px; z-index: 20; display: flex; align-items: center; gap: 4px; padding: 6px; border-radius: 999px; transform: translateX(-50%); background: rgb(58 58 62 / .6); backdrop-filter: blur(20px) saturate(1.5); -webkit-backdrop-filter: blur(20px) saturate(1.5); box-shadow: inset 0 0 0 1px rgb(255 255 255 / .15), 0 12px 34px rgb(0 0 0 / .2); }
.dock-item { position: relative; display: flex; align-items: center; justify-content: center; gap: 8px; min-width: 44px; height: 44px; border-radius: 999px; color: #f3f3f5; text-decoration: none; cursor: pointer; transition: background .25s, padding .35s var(--ease); }
.dock-item:hover { background: rgb(255 255 255 / .1); }
.dock-item.is-active { padding: 0 17px 0 14px; background: rgb(255 255 255 / .17); }
.dock-label { display: none; font-size: 14.5px; font-weight: 500; }
.dock-item.is-active .dock-label { display: inline; }
.dock-badge { position: absolute; top: 10px; right: 10px; width: 7px; height: 7px; border-radius: 50%; background: #f2b84b; }
.appearance { display: grid; gap: 12px; padding: 8px; }
.appearance-row { display: flex; flex-wrap: wrap; gap: 6px; }
.swatch, .dot, .font-chip, .lang-chip { border: 0; cursor: pointer; box-shadow: var(--card-shadow); transition: transform .2s var(--ease), box-shadow .2s; }
.swatch { width: 26px; height: 26px; border-radius: 8px; }
.swatch-auto { background: linear-gradient(135deg, #fbfbfa 50%, #151412 50%); }
.swatch-studio { background: #fbfbfa; } .swatch-light { background: #f6f3ec; } .swatch-sepia { background: #f1e6cf; }
.swatch-snow { background: #fdfdfc; } .swatch-dark { background: #151412; } .swatch-ink { background: #0f1319; }
.dot { width: 20px; height: 20px; border-radius: 50%; }
.dot-vermilion { background: #c1401b; } .dot-cobalt { background: #2c58c9; } .dot-moss { background: #3b7a3d; } .dot-graphite { background: #4b4a47; }
.font-chip, .lang-chip { min-width: 40px; height: 30px; padding: 0 10px; border-radius: 8px; background: var(--card); color: var(--ink); font-size: 13px; text-decoration: none; display: inline-flex; align-items: center; justify-content: center; }
.font-inter { font-family: "Inter Variable"; } .font-schibsted { font-family: "Schibsted Grotesk"; } .font-atkinson { font-family: "Atkinson Hyperlegible Next"; } .font-newsreader { font-family: "Newsreader"; }
[aria-pressed=true], .lang-chip.is-active { box-shadow: 0 0 0 2px var(--ink); }
```

- [ ] **Step 5: Run the tests, translate, and check visually**

- Run: `mise exec -- mix test test/acervo_web/live/archive_live_test.exs && mise run precommit`.
  Expected: PASS.
- Run `mix gettext.extract --merge` and fill in the new `pt_BR` strings:
  - "Coisas boas que eu encontro pela internet."
  - "Nada esperando."
  - "Nada salvo ainda."
  - "Navegação", "Aparência", "Tema", "Destaque", "Fonte", "Idioma"
  - "Sair", "Tudo", "Caixa de entrada"
  - "Um link" / "%{count} links", "uma coleção" / "%{count} coleções"
- Sign in on `http://localhost:4200` and use Tidewave `browser_eval` or a
  screenshot to compare with the prototype, option A.
- Check:
  - the equal-width columns;
  - `/inbox` opening the second column;
  - the dock with its active label;
  - the settings popover changing theme, accent and font live;
  - PT/EN switching.

- [ ] **Step 6: Ship**

Add to `CHANGELOG.md` `### Added`: "- Column navigation with the inbox, all
links and a floating dock with appearance and language settings." Commit
`feat: add the column shell and dock`, then open, check and merge the PR.

---

### Task 8: Release build and deploy pipeline

**Files:**
- Create: `lib/acervo_web/controllers/health_controller.ex`, `test/acervo_web/controllers/health_controller_test.exs`
- Create: `Dockerfile`, `.dockerignore`, `fly.toml`, `rel/` (via `mix phx.gen.release`), `lib/acervo/release.ex`
- Create: `.github/workflows/deploy.yml`, `guides/deployment.md`
- Modify: `lib/acervo_web/router.ex` (`get "/health"`), `config/runtime.exs`, `CONTRIBUTING.md` (deploy paragraph)

**Interfaces:**
- Produces: `GET /health`, which returns `{"status":"ok"}` (200) or `{"status":"unavailable"}` (503).
- Produces: the `Deploy release` workflow, triggered by `release: published`,
  not for prereleases. It reuses `ci.yml` through `workflow_call`, checks that
  the tag is on `main`, deploys with `flyctl` using `FLY_API_TOKEN`, and checks
  `/health`.

- [ ] **Step 1: Branch and write the failing health test**

```bash
git switch main && git pull --ff-only && git switch -c build/deploy-pipeline
```

`test/acervo_web/controllers/health_controller_test.exs`:

```elixir
defmodule AcervoWeb.HealthControllerTest do
  use AcervoWeb.ConnCase, async: true

  test "reports ok when the database answers", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get(~p"/health") |> json_response(200)
  end
end
```

Run it. Expected: FAIL (no route).

- [ ] **Step 2: Implement health**

```elixir
defmodule AcervoWeb.HealthController do
  use AcervoWeb, :controller

  def show(conn, _params) do
    case Acervo.Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> json(conn, %{status: "ok"})
      {:error, _} -> conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
    end
  end
end
```

In the router, add a pipeline-free scope: `scope "/", AcervoWeb do get "/health", HealthController, :show end`,
placed before the browser scope. Run the test. Expected: PASS.

- [ ] **Step 3: Release files**

Run: `mise exec -- mix phx.gen.release --docker`. Then align `Dockerfile` with
leitor's (`$L/Dockerfile`):
- Use the same `ELIXIR_VERSION`, `OTP_VERSION` and `DEBIAN_VERSION` args.
- Drop the `node` assets stage unless Task 4 added `assets/package.json`; if it
  did, keep that stage.
- Runtime packages: `libstdc++6 openssl libncurses6 libsctp1 locales ca-certificates`,
  without `poppler-utils` or Lumis.
- Copy from `/app/_build/prod/rel/acervo`.

Compare `rel/overlays/bin/migrate` and `server` with leitor's, which should be
identical apart from the names.

`fly.toml`:

```toml
app = "acervo-app"
primary_region = "gru"
kill_signal = "SIGTERM"
kill_timeout = "30s"

[build]
  dockerfile = "Dockerfile"

[deploy]
  release_command = "/app/bin/migrate"
  release_command_timeout = "5m"

[env]
  PHX_HOST = "acervo-app.fly.dev"
  PORT = "8080"
  POOL_SIZE = "5"
  ECTO_IPV6 = "true"
  DNS_CLUSTER_QUERY = "acervo-app.internal"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 1
  processes = ["app"]

  [[http_service.checks]]
    grace_period = "30s"
    interval = "15s"
    method = "GET"
    timeout = "5s"
    path = "/health"
    [http_service.checks.headers]
      X-Forwarded-Proto = "https"

[[vm]]
  cpu_kind = "shared"
  cpus = 1
  memory = "1gb"
```

In `config/runtime.exs`, change the prod `host` fallback from `"example.com"`
to `"acervo-app.fly.dev"`.

`.github/workflows/deploy.yml`: copy `$L/.github/workflows/deploy.yml` and
- delete the "Deploy the private figure checker" step;
- replace `leitor.fly.dev` with `acervo-app.fly.dev`;
- set the Actions SHAs (`actions/checkout`, `superfly/flyctl-actions/setup-flyctl`)
  to the ones `ci.yml` and leitor use, with the same `version: '0.4.116'` pin
  for flyctl.

`guides/deployment.md`: adapt leitor's guide (`$L/guides/deployment.md`),
covering:
- the publishing steps (identical);
- the database: a separate `acervo` database and role on `sisteo-apps-db`;
- the secrets: `DATABASE_URL`, `SECRET_KEY_BASE`, `ANTHROPIC_API_KEY`,
  `ACERVO_ALLOWED_EMAILS`, `RESEND_API_KEY`, `MAIL_FROM`, and the GitHub secret
  `FLY_API_TOKEN`;
- the pgvector requirement: `CREATE EXTENSION vector` runs in the first
  migration and needs either a trusted extension or a role allowed to create it.

In `CONTRIBUTING.md`, replace the "The deploy workflow will be added together
with the production target." sentence with "See the
[deployment guide](guides/deployment.md)."

- [ ] **Step 4: Verify the build locally**

Run: `MIX_ENV=prod mise exec -- mix release --overwrite`
Expected: the release is assembled at `_build/prod/rel/acervo`.
Run: `container build -t acervo:local .`, the Apple container equivalent of
`docker build`.
Expected: the image builds. Running it is not required; the production smoke
test happens in Task 9.

- [ ] **Step 5: Ship**

`mise run precommit`. Commit `build: add release build and Fly deploy workflow`, then open,
check and merge the PR. No CHANGELOG entry is needed.

---

### Task 9: Production provisioning and release 0.2.0

**This task contains a user checkpoint:** creating the Fly app and setting
secrets costs money and needs the owner's keys.

- [ ] **Step 1: Check the production database for pgvector**

Run, read-only: `fly postgres connect -a sisteo-apps-db -c "select name, default_version, installed_version from pg_available_extensions where name in ('vector','unaccent','citext')"`.
Run, read-only: `fly postgres connect -a sisteo-apps-db -c "select version()"`.
Record the results in the PR body. If `vector` is not available, stop and
report back with options: a dedicated Fly Postgres for acervo on a pgvector
image, or Supabase or Neon. Do not proceed.

- [ ] **Step 2: Checkpoint — ask the owner**

Present the exact commands and ask for approval, plus the secret values the
owner must provide (`ANTHROPIC_API_KEY`, `ACERVO_ALLOWED_EMAILS`,
`RESEND_API_KEY`, `MAIL_FROM`):

```bash
fly apps create acervo --org personal
fly postgres attach sisteo-apps-db --app acervo --database-name acervo --database-user acervo --superuser=false
# as admin, in the acervo database: GRANT CREATE ON DATABASE acervo TO acervo;
#   and, unless vector is trusted: CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS unaccent; CREATE EXTENSION IF NOT EXISTS citext;
fly secrets set --app acervo SECRET_KEY_BASE=$(mise exec -- mix phx.gen.secret) ANTHROPIC_API_KEY=... ACERVO_ALLOWED_EMAILS=... RESEND_API_KEY=... MAIL_FROM=...
fly tokens create deploy --app acervo --expiry 8760h | gh secret set FLY_API_TOKEN --repo emanoelims/acervo
```

Run them only after explicit approval.

- [ ] **Step 3: Prepare the release**

```bash
git switch main && git pull --ff-only && git switch -c chore/release-0.2.0
```

- Set `version: "0.2.0"` in `mix.exs`.
- In `CHANGELOG.md`, move the `[Unreleased]` entries under
  `## [0.2.0] - <today>` and add `### Migration`: "First deployment: extensions
  `citext`, `unaccent` and `vector`, users and tokens, and Oban. Configure the
  secrets in the deployment guide first."
- Commit `chore(release): prepare 0.2.0`, then open, check and merge the PR.

- [ ] **Step 4: Tag and publish**

```bash
git switch main && git pull --ff-only
git tag v0.2.0 && git push origin v0.2.0
gh release create v0.2.0 --title "0.2.0" --notes-file <(awk '/## \[0.2.0\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md)
gh run watch $(gh run list --workflow deploy.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
```

Expected: the `Deploy release` workflow passes, and
`curl -fsS https://acervo-app.fly.dev/health` returns `{"status":"ok"}`.

- [ ] **Step 5: Production smoke test**

- Open `https://acervo-app.fly.dev/users/register` and register the allowlisted
  email.
- Confirm the magic-link email arrives through Resend, then sign in.
- Check the column shell, the dock and switching appearance.
- Report the results to the owner.
