# Phase 2 — Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Saving a link works end to end:
- paste a URL, through the dock **+** or anywhere on the page;
- the link appears at once;
- a background job fetches its preview safely, using site-specific extractors;
- images are stored as WebP in the database and served privately;
- cards render in the column UI;
- a link opens in its own column, and can be noted, deleted, organised into manual collections, or given a screenshot when capture fails.

Also in this phase, sign-in creates the account for allowlisted emails, so the separate registration screen goes away. Shipped as `0.3.0`.

**Architecture:** Two contexts, as the spec says.
- **`Acervo.Library`:** links, images, URL normalization, the `SafeFetch` HTTP guard, extractors behind a behaviour, and the `CaptureLink` Oban worker.
- **`Acervo.Collections`:** collections and membership.

LiveView updates arrive over PubSub on the topic `"links:#{user_id}"`. Images go through `Acervo.Storage`, whose first implementation is `Acervo.Storage.Database`. All new tables use `Acervo.Schema` (UUID v7) and are scoped by `user_id`.

**Tech Stack:** Phoenix 1.8 / LiveView 1.2, Ecto + Postgres 18, Oban 2.24, Req 0.7 (with `Req.Test` for stubs), LazyHTML (moved to runtime), `image` (libvips via Vix) for WebP.

**Spec:** `docs/superpowers/specs/2026-10-18-acervo-design.md`, sections Data model, Capture pipeline, Interface. **Prototype:** `docs/superpowers/specs/2026-10-18-acervo-prototype.html`, option A. Cards, the link column and chips follow it.

## Global Constraints

- **PRs:** every PR title follows Conventional Commits. Squash-merge after `Conventions` and `Elixir checks` pass, using `gh pr merge --squash --admin --delete-branch`.
- **Before every commit:** run `mise run precommit` (Styler, `credo --strict`, tests). It must pass, and so must `ACERVO_ALLOWED_EMAILS=owner@example.com mise exec -- mix test`.
- **New dependencies:** use the newest release published at least 7 days before the work date. Check with `curl -s https://hex.pm/api/packages/<name>`.
- **Schemas:** use `use Acervo.Schema` (UUID v7). Every context function takes `%Acervo.Accounts.Scope{}` first and filters by `scope.user.id`. Nothing crosses users.
- **UI copy:**
  - Keep it minimal, with icons and `title` tooltips instead of labels.
  - Give key elements DOM ids.
  - Components never translate their inputs: callers pass `gettext(...)`.
  - Use English msgids, and fill in pt_BR for each with no empty msgstr. Mark custom changeset messages with `dgettext_noop("errors", ...)`.
- **Never fetch a user-supplied URL directly.** All outbound HTTP for capture goes through `Acervo.Library.SafeFetch`.
- **Tests make no network calls:**
  - HTTP goes through `Req.Test` stubs selected by config.
  - DNS goes through `Acervo.Library.Resolver`, which tests replace.
  - Oban runs in `testing: :manual` and is tested with `perform_job/2`.
- **CHANGELOG:** user-facing changes go under `## [Unreleased]`. New environment variables go in `mise.local.toml.example`.
- **Visual work:** for UI tasks, the controller verifies the result in a real browser (Chrome screenshots) against the prototype.
- **Dev server:** Postgres runs in the `acervo-db` Apple container on `localhost:5432`. The dev server runs on `:4200`; restart it after config or dependency changes.

---

### Task 1: Sign in creates the account for allowlisted emails

**Files:**
- Modify: `lib/acervo_web/live/user_live/login.ex`, `lib/acervo/accounts.ex`
- Delete: `lib/acervo_web/live/user_live/registration.ex`, `test/acervo_web/live/user_live/registration_test.exs`, `test/acervo_web/live/user_live/registration_locale_test.exs`, and the `/users/register` route and links
- Test: `test/acervo_web/live/user_live/login_test.exs`, `test/acervo/accounts_test.exs`

**Interfaces:**
- Produces: `Accounts.request_login_link(email, magic_link_url_fun) :: :ok`. It always returns `:ok`, so it never reveals whether an account exists.
  - Existing user: deliver login instructions; the 60-second throttle still applies.
  - No user and `Allowlist.allowed?(email)`: `register_user(%{email: email})`, then deliver.
  - Otherwise: do nothing.
  - Delivery errors are logged, as today.

- [ ] **Step 1:** Branch `feat/login-creates-account`. Write the failing tests:
  - `request_login_link/2` with an unknown allowlisted email creates the user and sends one email (`assert_email_sent`).
  - With an unknown email outside the allowlist, it creates nothing and sends nothing.
  - With an existing user, it sends.
  - LiveView: submitting the login form with a new allowlisted email shows the same "If your email is registered…" message as for an existing user, and an email is sent.
  - `/users/register` returns 404. Use `assert_error_sent 404` or the router's no-route behavior.
  - Set `Application.put_env(:acervo, :allowed_emails, [...])` and restore the previous value in `on_exit`; use `async: false`.
- [ ] **Step 2:** Run them and confirm they fail.
- [ ] **Step 3:** Implement:
  - Add `request_login_link/2` in `Accounts`.
  - Make `UserLive.Login` call it.
  - Delete the registration LiveView, its route and every link to it (`grep -rn "users/register\|Registration" lib test`).
  - Remove now-unused msgids with `mix gettext.extract --merge`.
- [ ] **Step 4:** Run `mise run precommit` and the allowlist-env run. Add to CHANGELOG `### Changed`: "Signing in with an allowed email creates the account; there is no separate sign-up screen."
- [ ] **Step 5:** Commit `feat: create the account when an allowed email signs in`, then open the PR, check CI and merge.

---

### Task 2: Links and collections schema

**Files:**
- Create: `lib/acervo/library/link.ex`, `lib/acervo/library/link_image.ex`, `lib/acervo/collections/collection.ex`, `lib/acervo/collections/collection_link.ex`
- Create migrations via `mix ecto.gen.migration create_links`, `create_link_images`, `create_collections`
- Test: `test/acervo/library/link_test.exs`, `test/acervo/collections/collection_test.exs`

**Interfaces:**
- **`Acervo.Library.Link`** (table `links`) has these fields:
  - Ownership and identity: `user_id` (binary_id, `on_delete: :delete_all`), `url` (string, max 2048), `canonical_url` (string, max 2048).
  - Source: `source` is `Ecto.Enum [:generic, :youtube, :instagram, :x]`.
  - Capture state: `status` is `Ecto.Enum [:pending, :processing, :ready, :failed]`, default `:pending`; `capture_error` is a string.
  - Content: `title`, `description`, `author`, `site_name` (strings), `published_at` (`:utc_datetime`), `text_excerpt` (string, at most 8000 characters).
  - Owner and triage: `note` (string), `triaged_at` (`:utc_datetime`).
  - Timestamps.
  - Constraints: a unique index on `[:user_id, :canonical_url]` and an index on `[:user_id, :inserted_at]`.
  - Changesets: `create_changeset(link, attrs)` casts url, canonical_url and source, and validates them as required. `capture_changeset(link, attrs)` casts the content fields, plus status and capture_error. `note_changeset(link, attrs)` casts note, at most 4000 characters.
- **`Acervo.Library.LinkImage`** (table `link_images`) has these fields:
  - `link_id` (`on_delete: :delete_all`), `position` (integer), `kind` (`Ecto.Enum [:preview, :screenshot]`).
  - `content_type`, `bytes` (`:binary`), `width`, `height`, `sha256` (string).
  - Timestamps, plus an index on `[:link_id, :position]`.
  - `Link` has `has_many :images, LinkImage, preload_order: [asc: :position]`.
- **`Acervo.Collections.Collection`** (table `collections`) has `user_id`, `name` (1–80 characters), `slug`, `description` (at most 280 characters) and `position` (integer, default 0), with a unique index on `[:user_id, :slug]`. `changeset/2` derives `slug` from `name`: downcase, transliterate accents with `:unicode.characters_to_nfd_binary` and strip combining marks, then replace non-alphanumerics with `-`. Changing the name re-derives the slug.
- **`Acervo.Collections.CollectionLink`** (table `collection_links`) has `collection_id` and `link_id` (both `on_delete: :delete_all`), `source` (`Ecto.Enum [:manual, :suggestion]`, default `:manual`) and `inserted_at`, with a unique index on `[:collection_id, :link_id]`. `Link` has `many_to_many :collections, Collection, join_through: CollectionLink`.

- [ ] **Step 1:** Branch `feat/library-schema`. Write changeset tests:
  - The required fields.
  - The length limits.
  - The slug derivation: `"Inspiração de UI"` becomes `"inspiracao-de-ui"`, and a rename re-derives it.
  - The unique constraint error on a duplicate `(user_id, canonical_url)`, inserted through `Repo.insert` with `unique_constraint`.
- [ ] **Step 2:** Run them and confirm they fail.
- [ ] **Step 3:** Write the migrations and schemas. Foreign keys use `references(:users, type: :binary_id, on_delete: :delete_all)`, and the timestamps use `type: :utc_datetime`.
- [ ] **Step 4:** Migrate (`mise exec -- mix ecto.migrate`) and run `mise run precommit`.
- [ ] **Step 5:** Commit `feat: add links, images and collections tables`, then open the PR, check CI and merge.

---

### Task 3: URL normalization and source detection

**Files:**
- Create: `lib/acervo/library/url.ex`
- Test: `test/acervo/library/url_test.exs`

**Interfaces:**
- Produces: `Acervo.Library.URL.normalize(String.t()) :: {:ok, String.t()} | {:error, :invalid_url}`.
- Produces: `Acervo.Library.URL.source(String.t()) :: :generic | :youtube | :instagram | :x`. It takes a canonical URL.

Normalization rules, applied in order:
1. Trim the input. Accept only `http` and `https`. A bare domain like `example.com/page` gets `https://`. The host must contain a dot or be `localhost`. Reject everything else.
2. Lowercase the scheme and host. Drop the default port (80 for http, 443 for https), the fragment and the userinfo.
3. **X:** the hosts `twitter.com`, `www.twitter.com`, `mobile.twitter.com`, `x.com`, `www.x.com` and `mobile.x.com` become `x.com`.
4. **YouTube:**
   - `youtu.be/ID` becomes `https://www.youtube.com/watch?v=ID`.
   - `youtube.com/shorts/ID` and `m.youtube.com/watch?v=ID` become the same `watch?v=ID` form.
   - Only the `v` query param is kept for watch URLs.
5. **Instagram:** `instagram.com` and `www.instagram.com` become `www.instagram.com`. All query params are dropped.
6. **Tracking params:** drop `utm_*`, `fbclid`, `gclid`, `dclid`, `mc_cid`, `mc_eid`, `igsh`, `igshid`, `si`, `ref_src`, `ref_url`. On `x.com`, also drop `s` and `t`. On YouTube, drop `feature` and `pp`. Keep the remaining params in their original order. An empty query string is removed entirely.
7. A trailing `/` on a path other than the root is removed.

- [ ] **Step 1:** Branch `feat/url-normalization`. Write table-driven tests, each a pair of input and expected output:

```elixir
for {input, expected} <- [
      {"https://Example.com/Page/?utm_source=x&id=3#top", "https://example.com/Page?id=3"},
      {"example.com", "https://example.com/"},
      {"http://example.com:80/a/", "http://example.com/a"},
      {"https://youtu.be/dQw4w9WgXcQ?si=abc", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
      {"https://m.youtube.com/watch?v=dQw4w9WgXcQ&feature=share&t=10", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
      {"https://www.youtube.com/shorts/abc123", "https://www.youtube.com/watch?v=abc123"},
      {"https://twitter.com/user/status/1?s=20&t=xyz", "https://x.com/user/status/1"},
      {"https://instagram.com/p/Cx1/?igsh=abc&img_index=1", "https://www.instagram.com/p/Cx1"}
    ] do
  test "normalizes #{input}" do
    assert {:ok, unquote(expected)} = URL.normalize(unquote(input))
  end
end
```

Add rejection tests for `""`, `"ftp://x.com"`, `"javascript:alert(1)"`, `"not a url"` and `"http://"`. Add `source/1` tests for each provider.
- [ ] **Step 2:** Run the tests and confirm they fail.
- [ ] **Step 3:** Implement with the `URI` module only. Build every list (the tracking params and hosts) as a module attribute.
- [ ] **Step 4:** Run `mise run precommit`.
- [ ] **Step 5:** Commit `feat: normalize link URLs and detect their source`, then open the PR, check CI and merge.

---

### Task 4: SafeFetch — guarded outbound HTTP

**Files:**
- Create: `lib/acervo/library/resolver.ex` (behaviour plus default implementation), `lib/acervo/library/safe_fetch.ex`
- Modify: `config/test.exs`
- Test: `test/acervo/library/safe_fetch_test.exs`, `test/support/static_resolver.ex`

**Interfaces:**
- Produces: `Acervo.Library.Resolver` with `@callback resolve(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, term()}`.
  - The default implementation, `Acervo.Library.Resolver.Inet`, merges `:inet.getaddrs(host, :inet)` and `:inet.getaddrs(host, :inet6)`.
  - It is selected by `Application.get_env(:acervo, :resolver, Acervo.Library.Resolver.Inet)`.
- Produces: `Acervo.Library.SafeFetch.get(url, opts) :: {:ok, %{status: integer, headers: map, body: binary, url: String.t()}} | {:error, reason}`.
  - Options:
    - `:max_bytes`, default 3_000_000;
    - `:accept`, the Accept header;
    - `:user_agent`, default `"Mozilla/5.0 (compatible; AcervoBot/1.0; +https://acervo-app.fly.dev)"`;
    - `:max_redirects`, default 5.
  - Reasons: `:invalid_url`, `:blocked_address`, `:bad_port`, `:too_many_redirects`, `:too_large`, `:timeout`, `{:http, status}` for non-2xx after redirects, and `{:transport, term}`.
- Produces: `SafeFetch.blocked_ip?(:inet.ip_address()) :: boolean`, which is public so it can be unit-tested.

Rules:
- Only http and https, only ports 80 and 443 (implicit or explicit), and no userinfo.
- **Resolution:** resolve the host through the configured resolver. If *any* resolved address is blocked, return `{:error, :blocked_address}`. IP literals in the URL are checked directly.
- **Blocked ranges:**
  - IPv4: `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8`, `169.254.0.0/16`, `172.16.0.0/12`, `192.0.0.0/24`, `192.168.0.0/16`, `198.18.0.0/15`, `224.0.0.0/4`, `240.0.0.0/4`, `255.255.255.255`.
  - IPv6: `::`, `::1`, `fc00::/7`, `fe80::/10`, `ff00::/8`, and IPv4-mapped `::ffff:a.b.c.d`, which is checked as IPv4.
- **Connection pinning:** connect to the first allowed IP, so DNS can't change between the check and the connection. Do it with `Req.request(url: <same URL with the host replaced by the IP literal, bracketed for IPv6>, headers: [{"host", host}], connect_options: [hostname: host, timeout: 10_000], receive_timeout: 10_000, redirect: false, retry: false, decode_body: false)`. Merge `Application.get_env(:acervo, :safe_fetch_req_options, [])` last; tests set `plug: {Req.Test, Acervo.Library.SafeFetch}`. When the plug option is present, Req skips the network, and tests assert the request host and header.
- **Size limit:** stream the body with `into:` a function that accumulates and halts with `:too_large` past `:max_bytes`. Also reject early on a `content-length` larger than `:max_bytes`.
- **Redirects:**
  - 301, 302, 303, 307 and 308 with a `location` header: resolve it against the current URL, re-run every check, and follow it until `:max_redirects`.
  - The returned `:url` is the final URL.

- [ ] **Step 1:** Branch `feat/safe-fetch`. Write the tests.
  - `blocked_ip?/1` for one address inside each blocked range, plus `{8,8,8,8}` and `{0x2001,0x4860,0,0,0,0,0,0x8888}` as allowed.
  - **Resolver blocking:** a `StaticResolver` that maps `"internal.test"` to `{10,0,0,5}` makes `get("https://internal.test/")` return `{:error, :blocked_address}`, and no request reaches `Req.Test`: use `Req.Test.expect` with 0 calls, or stub-and-refute.
  - **Pinning:** `"public.test"` resolves to `{93,184,216,34}`. The stub asserts `conn.host == "93.184.216.34"` and `Plug.Conn.get_req_header(conn, "host") == ["public.test"]`, then returns 200 with "ok". The result is `{:ok, %{status: 200, body: "ok", url: "https://public.test/"}}`.
  - **Redirect to private:** the stub returns 302 with `location: http://internal.test/x`, which gives `{:error, :blocked_address}`.
  - **Redirect loop:** six 302s give `{:error, :too_many_redirects}`.
  - **Body size:** a body over `max_bytes` gives `{:error, :too_large}`.
  - **Port:** `https://public.test:8080/` gives `{:error, :bad_port}`.
  - **Bad URLs:** `ftp://public.test`, `https://user:pw@public.test/` and the IP literal `http://127.0.0.1/` all give errors.
  - **Error status:** a 404 response gives `{:error, {:http, 404}}`.
- [ ] **Step 2:** Run the tests and confirm they fail.
- [ ] **Step 3:** Implement.
  - `test/support/static_resolver.ex` reads a map from `Application.get_env(:acervo, :static_hosts, %{})`, and tests put the entries they need.
  - `config/test.exs` sets `config :acervo, :resolver, Acervo.StaticResolver` and `config :acervo, :safe_fetch_req_options, plug: {Req.Test, Acervo.Library.SafeFetch}`.
  - Use a fixed pinned IP literal in the URL, because `Req.Test` ignores the host anyway.
- [ ] **Step 4:** Run `mise run precommit`.
- [ ] **Step 5:** Commit `feat: guard outbound capture requests against SSRF`, then open the PR, check CI and merge.

---

### Task 5: Image normalization and private serving

**Files:**
- Modify: `mix.exs` (add `{:image, ...}`; move `lazy_html` out of `only: :test` because Task 6 needs it at runtime)
- Create: `lib/acervo/storage.ex` (behaviour), `lib/acervo/storage/database.ex`, `lib/acervo/library/images.ex`, `lib/acervo_web/controllers/image_controller.ex`
- Modify: `lib/acervo_web/router.ex` (`get "/images/:id"` inside the authenticated browser scope)
- Test: `test/acervo/library/images_test.exs`, `test/acervo_web/controllers/image_controller_test.exs`, fixtures `test/support/fixtures/images/{photo.jpg,wide.png,not_image.txt}`

**Interfaces:**
- Produces: `Acervo.Library.Images.normalize(binary) :: {:ok, %{bytes: binary, content_type: "image/webp", width: pos_integer, height: pos_integer, sha256: String.t()}} | {:error, :not_an_image | :too_large}`.
  - It decodes with `Image.from_binary/1`, auto-rotates using EXIF, strips metadata, and limits the long side to 1600 px with `Image.thumbnail/3` and `resize: :down`.
  - It writes with `Image.write(img, :memory, suffix: ".webp", quality: 80)`.
  - Input over 15 MB returns `{:error, :too_large}`.
- Produces: `Acervo.Storage` with `@callback put(scope, link, attrs :: map) :: {:ok, LinkImage.t()} | {:error, Ecto.Changeset.t()}` and `@callback fetch(scope, id) :: {:ok, LinkImage.t()} | :error`. `fetch` only returns images whose link belongs to `scope.user`.
- Produces: `Acervo.Storage.Database`, the Repo-backed implementation. The active implementation comes from `Application.get_env(:acervo, :storage, Acervo.Storage.Database)`.
- Produces: `GET /images/:id`.
  - It returns 200 with the bytes, `content-type` from the record, and `cache-control: private, max-age=31536000, immutable`, plus an `etag` from sha256.
  - It returns 404 for a missing image, another user's image or a malformed id.
  - It requires authentication: the authenticated scope redirects visitors.

- [ ] **Step 1:** Branch `feat/images`. Add the `image` dependency, following the 7-day rule.
  - Run `mise exec -- mix deps.get`.
  - Confirm that Vix's precompiled NIF loads: `mise exec -- mix run -e 'Image.new!(2, 2) |> Image.write!(:memory, suffix: ".webp") |> byte_size() |> IO.inspect'`.
  - Create the fixtures. Write a 2400×1200 JPG with `Image.new!(2400, 1200, color: :red) |> Image.write!("test/support/fixtures/images/photo.jpg")`. Commit the small PNG as well.
- [ ] **Step 2:** Write the tests.
  - Normalizing photo.jpg gives `width == 1600`, `height == 800` and `content_type == "image/webp"`.
  - A small image is not enlarged.
  - The text file gives `:not_an_image`.
  - Storage `fetch` for another user returns `:error`.
  - Controller: the owner gets 200 with the headers above; another user gets 404; a visitor is redirected to log in; a malformed id gets 404.
- [ ] **Step 3:** Run the tests and confirm they fail.
- [ ] **Step 4:** Implement.
- [ ] **Step 5:** Check the production image. Run `container build -t acervo:local .`, then `container run --rm -e SECRET_KEY_BASE=x... acervo:local /app/bin/acervo eval 'Image.new!(2,2) |> Image.write!(:memory, suffix: ".webp") |> byte_size() |> IO.puts'`. It must print a number. If libvips needs extra runtime packages in the Debian runner, add them to the Dockerfile runner `apt-get install`.
- [ ] **Step 6:** Run `mise run precommit`, then commit `feat: normalize images to WebP and serve them privately`, then open the PR, check CI and merge.

---

### Task 6: Extractors — generic, YouTube, X, Instagram

**Files:**
- Create: `lib/acervo/library/capture.ex` (struct), `lib/acervo/library/extractor.ex` (behaviour plus dispatch), `lib/acervo/library/extractors/{generic,youtube,x,instagram}.ex`, `lib/acervo/library/html_meta.ex` (shared parsing)
- Test: one test file per extractor in `test/acervo/library/extractors/`, with fixtures in `test/support/fixtures/pages/*.html|*.json`

**Interfaces:**
- Produces: `%Acervo.Library.Capture{title, description, author, site_name, published_at, text, image_urls: [String.t()], canonical_url}`. Every field is optional.
- Produces: `Acervo.Library.Extractor`:
  - `@callback match?(URI.t()) :: boolean`
  - `@callback extract(URI.t()) :: {:ok, Capture.t()} | {:error, :blocked | :not_found | :timeout | {:http, integer} | term}`
  - `Extractor.for(uri)` returns the first matching module from `[YouTube, X, Instagram]`, falling back to `Generic`.
  - `Extractor.extract(url_string)` dispatches to it.
- Produces: `HtmlMeta.parse(html :: binary, base_url :: String.t()) :: Capture.t()`, using LazyHTML.
  - **title:** `og:title`, else `twitter:title`, else `<title>`.
  - **description:** `og:description`, else `twitter:description`, else `meta[name=description]`.
  - **site_name:** `og:site_name`.
  - **author:** `meta[name=author]`, else `article:author`.
  - **published_at:** `article:published_time`, parsed with `DateTime.from_iso8601`, else nil.
  - **image_urls:** every `og:image`, `og:image:secure_url` and `twitter:image`, absolutized against `base_url`, deduplicated, up to 4.
  - **text:** the main text. Prefer `article`, else `main`, else `body`. Drop `script`, `style`, `nav`, `header`, `footer` and `aside`. Collapse whitespace and truncate to 8000 characters.
  - **canonical_url:** `link[rel=canonical]`, absolutized.

Extractor behavior (all HTTP goes through `SafeFetch`):
- **Generic:** `SafeFetch.get(url, accept: "text/html,application/xhtml+xml")`. A response that isn't HTML gives `{:error, :not_html}`. On HTML, return `HtmlMeta.parse`.
- **YouTube:**
  - Read the `v` param.
  - Call `SafeFetch.get("https://www.youtube.com/oembed?url=#{URI.encode_www_form(url)}&format=json")` and decode it with Jason. Its `title` gives the title, `author_name` the author, and `provider_name` the site name.
  - `image_urls` are `["https://i.ytimg.com/vi/#{id}/maxresdefault.jpg", "https://i.ytimg.com/vi/#{id}/hqdefault.jpg"]`. The worker uses the first one that downloads.
  - An oEmbed 404 or 401 gives `{:error, :not_found}`.
- **X:**
  - Call `SafeFetch.get("https://publish.twitter.com/oembed?url=#{encoded}&omit_script=true")`. `author_name` gives the author. The text is the `<p>` inside the `html` blockquote, extracted with LazyHTML and stripped of markup. The title is `"#{author_name} on X"`.
  - Then try `Generic` for `image_urls`. Ignore its errors, because X often blocks.
  - An oEmbed 404 gives `{:error, :not_found}`.
- **Instagram:**
  - Use `Generic` with `user_agent: "facebookexternalhit/1.1"`.
  - If the result has no `og:image` and the page looks like a login wall (the URL redirected to `/accounts/login`, or the title is "Instagram" with no description), return `{:error, :blocked}`.

- [ ] **Step 1:** Branch `feat/extractors`. Save realistic fixtures by hand, without fetching live in tests. Write each fixture as a minimal HTML or JSON document containing the relevant tags:
  - an article page with OG tags and `article` text;
  - a page with only `<title>` and a meta description;
  - a YouTube oEmbed JSON;
  - an X oEmbed JSON whose `html` field contains a blockquote;
  - an Instagram page with `og:image`;
  - an Instagram login-wall page.
- [ ] **Step 2:** Write the tests. Stub `Req.Test` per URL, branching on `conn.request_path` and `conn.query_string`, and register the hosts in `StaticResolver`.
  - **HtmlMeta:** cover every fallback chain, absolutizing relative `og:image`, deduplication, the 4-image cap, and text cleaning.
  - **Dispatch:** `Extractor.for/1` picks the right module per host.
  - **Per extractor:** each returns the expected `Capture`, and each maps its error cases.
- [ ] **Step 3:** Run the tests and confirm they fail.
- [ ] **Step 4:** Implement.
- [ ] **Step 5:** Run `mise run precommit`.
- [ ] **Step 6:** Commit `feat: extract link previews for web, YouTube, X and Instagram`, then open the PR, check CI and merge.

---

### Task 7: Library context and the capture worker

**Files:**
- Create: `lib/acervo/library.ex`, `lib/acervo/library/capture_link.ex` (Oban worker)
- Test: `test/acervo/library_test.exs`, `test/acervo/library/capture_link_test.exs`, `test/support/fixtures/library_fixtures.ex`

**Interfaces** (all take `scope` first):
- **`save_link(scope, url) :: {:ok, Link.t(), :created | :existing} | {:error, :invalid_url | Ecto.Changeset.t()}`.**
  - It normalizes the URL with `URL.normalize/1` and returns the existing link on `(user_id, canonical_url)`.
  - Otherwise it uses one `Ecto.Multi`: insert the link (`source` from `URL.source/1`), then `Oban.insert(CaptureLink.new(%{"link_id" => id}))`.
  - On `:created` it broadcasts `{:link_created, link}`.
- **`list_links(scope, opts)`:**
  - `opts[:filter]` is `:all` (newest first), `:inbox` (`triaged_at` is nil), or `{:collection, collection_id}`.
  - It preloads the first image only (`images` limited to position 0) and the collections.
  - `opts[:limit]` defaults to 60.
- **`get_link!(scope, id)`** preloads images and collections, and raises on another user's id.
- **`count_links(scope)`** and **`count_inbox(scope)`**.
- **`update_note(scope, link, attrs)`** broadcasts `{:link_updated, link}`.
- **`mark_triaged(scope, link)`** sets `triaged_at` to now and broadcasts `{:link_updated, link}`.
- **`delete_link(scope, link)`** broadcasts `{:link_deleted, link}`.
- **`attach_screenshot(scope, link, binary)`** runs `Images.normalize`, stores a `:screenshot` at position 0 (moving existing images down), sets `status: :ready` and clears `capture_error`, then broadcasts `{:link_updated, link}`.
- **`subscribe(scope)`** does `Phoenix.PubSub.subscribe(Acervo.PubSub, "links:#{scope.user.id}")`.
- **`Acervo.Library.CaptureLink`** is an Oban worker on queue `:capture`, with `max_attempts: 5` and `unique: [period: 60, keys: [:link_id]]`.
  - It loads the link. If the link is gone, it returns `:ok`.
  - It sets `:processing` and runs `Extractor.extract(link.url)`.
  - **On `{:ok, capture}`:**
    - Download each image with `SafeFetch.get(img, max_bytes: 15_000_000, accept: "image/*")`, stopping after 4 stored or when the list runs out.
    - For each download, run `Images.normalize` and store it as a `:preview`. Skip failures.
    - Then apply the capture fields with `status: :ready`. Only replace `canonical_url` if no other link of this user already has it.
  - **On `{:error, reason}` where reason is `:blocked`, `:not_found`, `:not_html`, `:blocked_address`, `:bad_port` or `{:http, 4xx}`:** set `status: :ready` and `capture_error: Atom.to_string(reason)` (use `"http_404"` style for tuples), and return `:ok`, so there is no retry.
  - **On a transient error** (`:timeout`, `{:transport, _}`, `{:http, 5xx}`, `:too_large`): if attempts remain, set the status back to `:pending` and return `{:error, reason}` so Oban retries. On the final attempt, set `status: :failed` with a `capture_error`.
  - It always broadcasts `{:link_updated, link}` at the end.

- [ ] **Step 1:** Branch `feat/library-context`. Write the tests.
  - **Context:**
    - `save_link` dedupes on the canonical form: `save_link(s, "https://x.com/a?s=1")` and then `save_link(s, "https://twitter.com/a")` give `:existing`.
    - It enqueues exactly one job (`assert_enqueued worker: CaptureLink`).
    - An invalid URL gives `{:error, :invalid_url}`.
    - Isolation: user B can't `get_link!` user A's link (`assert_raise Ecto.NoResultsError`), and the list and count functions are scoped.
    - `update_note` and `mark_triaged` work.
    - `attach_screenshot` puts the screenshot first.
    - Subscribers receive the messages.
  - **Worker:** use `perform_job(CaptureLink, %{"link_id" => id})` with `Req.Test` stubs and `StaticResolver`.
    - The success path stores the images (WebP; use a fixture JPG served by the stub) and fills the fields.
    - A permanent error leaves the link `:ready` with `capture_error`.
    - A transient error on attempt 1 returns `{:error, _}` with status `:pending`; on the max attempt (`attempt: 5` via `perform_job` opts) it ends `:failed`.
    - A deleted link returns `:ok`.
- [ ] **Step 2:** Run the tests and confirm they fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `mise run precommit`.
- [ ] **Step 5:** Commit `feat: save links and capture their previews in the background`, then open the PR, check CI and merge.

---

### Task 8: Collections context

**Files:**
- Create: `lib/acervo/collections.ex`
- Test: `test/acervo/collections_test.exs`, `test/support/fixtures/collections_fixtures.ex`

**Interfaces** (scope first, all user-isolated):
- `list_collections(scope)`. Ordered by `position`, then `name`. Each carries a virtual `link_count` and `cover_image_ids`: up to 4 `link_images.id` of the most recent links with an image. Add both as `field :link_count, :integer, virtual: true` and `field :cover_image_ids, {:array, :binary_id}, virtual: true` on the schema.
- `get_collection_by_slug!(scope, slug)`.
- `create_collection(scope, attrs)`. On a duplicate slug, the changeset gets an error on `:name`.
- `update_collection(scope, collection, attrs)`.
- `delete_collection(scope, collection)`. Links remain.
- `add_link(scope, collection, link)`. Idempotent, with `on_conflict: :nothing`.
- `remove_link(scope, collection, link)`.
- `change_collection(collection, attrs \\ %{})`.
- Each mutation broadcasts on the same topic: `{:collections_changed}` or `{:link_updated, link}`.

- [ ] **Step 1:** Branch `feat/collections-context`. Write tests:
  - CRUD.
  - Slug collision, including two names that slugify the same way.
  - `add_link` twice gives one row.
  - User isolation, including adding user A's link to user B's collection. That must raise or return `{:error, :not_found}`; choose `{:error, :not_found}` and test it.
  - The counts and cover ids.
  - Deleting a collection keeps its links.
- [ ] **Step 2:** Run the tests and confirm they fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `mise run precommit`.
- [ ] **Step 5:** Commit `feat: organize links into manual collections`, then open the PR, check CI and merge.

---

### Task 9: Cards, the link column and live updates

**Files:**
- Modify: `lib/acervo_web/live/archive_live.ex`, `lib/acervo_web/components/archive_components.ex`, `lib/acervo_web/router.ex`, `assets/css/archive.css`
- Create: `lib/acervo_web/components/link_components.ex` (cards, link detail, source icon)
- Add the Lucide icons this task uses (from `lucide-static`, at the version noted in `assets/vendor/lucide/README`, in the same single-line format) and source brand marks as inline SVG in the component. The marks to copy are X, YouTube, Instagram and a globe, from the prototype's `<symbol>`s.
- Test: `test/acervo_web/live/archive_live_test.exs`, plus a new `test/acervo_web/live/link_column_test.exs`

**Interfaces:**
- **Routes,** each a `live_action` of `ArchiveLive`:
  - `/all` and `/all/l/:id` give `:all` and `:all_link`.
  - `/inbox` and `/inbox/l/:id` give `:inbox` and `:inbox_link`.
  - `/c/:slug` and `/c/:slug/l/:id` give `:collection` and `:collection_link`.
- **Streams:** use the stream `:links` for the list column, resetting it whenever the filter changes.
  - `handle_info` for `{:link_created, link}` inserts at the top (`at: 0`) when the link matches the current filter.
  - `{:link_updated, link}` re-inserts the link: re-fetch it with `get_link!` so the preloads are present.
  - `{:link_deleted, link}` deletes it.
  - Every message updates `total_count` and `inbox_count`.
- **Cards** (`LinkComponents.card/1`, attrs `link`, `patch`, `selected`), following the prototype's card markup and CSS translated to tokens:
  - **Image card:** used when the link has an image. The image sits over a blurred copy of itself, `<img src={~p"/images/#{image.id}"}>`.
  - **Video card:** used when the source is `:youtube` and there is an image. It shows the date, the title and a 16:9 thumbnail with a play badge.
  - **Text card:** used otherwise. It shows the date, the title and a 2-line description.
  - A source icon sits at the top right.
  - **`status` `:pending`/`:processing`:** the card shows a calm skeleton shimmer instead of an image, with the host as the title.
  - **`capture_error` set and no image:** a text card with a subtle camera icon offering a screenshot. The screenshot upload itself comes in Task 11.
  - DOM id `link-#{id}` (from the stream).
- **Link column** (`LinkComponents.link_detail/1`, DOM id `column-link`):
  - Shows the title and the visual: every image in a vertical stack, the first one in the glow treatment.
  - The meta line is author · site · date.
  - Collection chips: filled chips, each a `patch` to `/c/:slug`.
  - The note: `<.form id="note-form">` with a textarea that saves on blur and on submit (`phx-submit="save_note"`).
  - Round icon actions with tooltips:
    - **Open original:** `target="_blank" rel="noopener noreferrer"`, id `link-open`.
    - **Done (✓):** only while `triaged_at` is nil, id `link-done`. It marks the link triaged and leaves the column on the inbox route.
    - **Delete:** id `link-delete`, with a `data-confirm` via `phx-click` and `JS` confirm. The controller avoids clicking it in automated browser checks.
- **Column 1** gains the collections list under Inbox and All: `nav_item` with `navigate={~p"/c/#{slug}"}` and `count`. Task 10 adds the "new collection" control.
- **Counts:** `total_count`, `inbox_count` and `collections_count` come from the contexts. The lead sentence's counts become `<.link patch>` underlined links, as in the prototype: links go to `/all`, and inbox goes to `/inbox`.
- The page title is the link title on link routes.

- [ ] **Step 1:** Branch `feat/link-cards`. Write LiveView tests by element id.
  - `/all` lists the user's links (`#links #link-<id>`) newest first, and another user's link isn't shown.
  - Clicking a card patches to `/all/l/:id` and shows `#column-link`.
  - Saving a note persists.
  - `#link-done` on `/inbox/l/:id` marks the link triaged, removes it from the inbox stream and patches back to `/inbox`.
  - Delete removes the card.
  - A broadcast `{:link_updated, link}` re-renders the card. Test it by calling `Library.update_note` from the test process and then `render(view)`.
  - Visiting `/all/l/<other-users-id>` redirects to `/all` with an error flash. It must not crash: rescue `Ecto.NoResultsError` in `handle_params`.
- [ ] **Step 2:** Run the tests and confirm they fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `mise run precommit`, then fill pt_BR for the new msgids.
- [ ] **Step 5:** The controller checks the result visually: seed links with images in dev and compare to the prototype.
- [ ] **Step 6:** Commit `feat: show links as cards and open them in their own column`, then open the PR, check CI and merge.

---

### Task 10: Add, paste and organize

**Files:**
- Modify: `lib/acervo_web/components/archive_components.ex` (dock **+** and the floating input pill), `lib/acervo_web/live/archive_live.ex`, `lib/acervo_web/components/link_components.ex`, `assets/css/archive.css`
- Test: `test/acervo_web/live/add_link_test.exs`, `test/acervo_web/live/collections_ui_test.exs`

**Interfaces:**
- **Dock add button,** `#dock-add` with a plus icon:
  - It toggles a floating pill above the dock (`#add-pill`), as in the prototype, containing `<.form id="add-link-form" phx-submit="add_link">` with a single URL input (`name="url"`, placeholder `gettext("Paste a link")`, autofocus) and Enter to submit. `Esc` closes it.
  - On `{:ok, link, :created}` the pill closes, the URL patches to `/inbox/l/#{id}`, and the info flash is `gettext("Saved.")`.
  - On `:existing` it patches to the existing link with the flash `gettext("Already in your archive.")`.
  - On `:invalid_url` it shows an inline error in the pill.
- **Paste anywhere:**
  - A colocated hook `.PasteLink` sits on `#columns`.
  - It listens for `paste` on `window`, and ignores the event when the target is an `input`, a `textarea` or a contenteditable.
  - When the clipboard text trimmed looks like a URL (`/^(https?:\/\/)?[^\s]+\.[^\s]{2,}$/`), it calls `pushEvent("add_link", {url})`. That is the same server handler.
- **Organizing in the link column:**
  - An "add to collection" round button (`#link-add-collection`) opens a `<.popover>`.
  - Inside is a filterable list of collections (`phx-change` filter input `#collection-filter`). Clicking a row (`#collection-option-#{id}`) adds the link to that collection.
  - The last row is `+ "#{query}"`, which creates the collection with that name and adds the link (`#collection-create`).
  - Each filled chip has a small ✕ (`#chip-remove-#{collection_id}`) that removes the link from the collection.
- **Collection management:**
  - In column 1, a subtle `+` after the collections (`#new-collection`) opens a small inline form, `#new-collection-form`, which takes a name.
  - A collection column's `···` popover (`#collection-menu`) offers:
    - Rename, an inline form (`#rename-collection-form`). A changed slug patches the URL.
    - Description, a textarea form (`#describe-collection-form`).
    - Delete (`#delete-collection`, with confirm). It patches to `/` and keeps the links.
  - The collection column shows its description under the title, like the prototype's `.desc`.

- [ ] **Step 1:** Branch `feat/add-and-organize`. Write the tests.
  - Submitting `#add-link-form` with a URL creates the link and patches to `/inbox/l/:id`.
  - Submitting the same URL again patches to the existing link.
  - An invalid URL shows the error.
  - `render_hook(view, "add_link", %{"url" => ...})` behaves the same way.
  - Collection create, rename (the URL follows the new slug), describe and delete.
  - Adding a link to an existing collection and to a new one from the popover.
  - Removing via the chip ✕.
- [ ] **Step 2:** Run the tests and confirm they fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `mise run precommit` and fill in pt_BR.
- [ ] **Step 5:** The controller checks visually: paste a real URL in dev, watch the card fill in live, and organize it.
- [ ] **Step 6:** Commit `feat: add links by pasting and organize them into collections`, then open the PR, check CI and merge.

---

### Task 11: Screenshot fallback

**Files:**
- Modify: `lib/acervo_web/live/archive_live.ex`, `lib/acervo_web/components/link_components.ex`
- Test: `test/acervo_web/live/screenshot_upload_test.exs`

**Interfaces:**
- **Upload setup:** `allow_upload(:screenshot, accept: ~w(.png .jpg .jpeg .webp .heic), max_entries: 1, max_file_size: 15_000_000, auto_upload: true, progress: &handle_progress/3)` in the link column.
- **Where it shows:** the link column shows a drop zone (`#screenshot-drop`, `phx-drop-target`) with a camera icon when the link has no images or has a `capture_error`. A small camera action (`#link-screenshot`) is always present.
- **On upload done:** `consume_uploaded_entries` reads the file and calls `Library.attach_screenshot/3`.
  - On `{:error, :not_an_image}`, it shows the flash `gettext("That file isn't an image.")`.
- **Paste an image:** while the link column is open, pasting an image from the clipboard into it uploads that image. The `.PasteLink` hook checks `clipboardData.files` first; when a link column is open, it uses `this.upload("screenshot", files)` from a hook element inside the link column.

- [ ] **Step 1:** Branch `feat/screenshot-fallback`. Write tests using `file_input/4` and `render_upload/3` with the fixture `photo.jpg`. The screenshot must be stored at position 0, and `capture_error` must be cleared. A text file must produce the error flash.
- [ ] **Step 2:** Run the tests and confirm they fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `mise run precommit`. The controller checks visually.
- [ ] **Step 5:** Commit `feat: add a screenshot when a preview can't be captured`, then open the PR, check CI and merge.

---

### Task 12: Release 0.3.0

- [ ] **Step 1: Production check (read-only).**
  - Confirm the `image` NIF works in the deployed image after the deploy, via `fly ssh console -a acervo-app -C '/app/bin/acervo rpc "IO.inspect(Image.new!(2,2) |> Image.write!(:memory, suffix: \".webp\") |> byte_size())"'`.
  - Confirm that outbound requests from Fly work for each extractor. After deploy, save one real link of each kind in production.
- [ ] **Step 2:** Branch `chore/release-0.3.0`.
  - Set `version: "0.3.0"`.
  - Move the CHANGELOG `[Unreleased]` entries to `## [0.3.0] - <date>`, curated.
  - Add a `### Migration` note: new tables `links`, `link_images`, `collections` and `collection_links`. Images live in the database; the volume is 10 GB.
  - Run `mise run precommit`, then commit `chore(release): prepare 0.3.0`, open the PR, check CI and merge.
- [ ] **Step 3:** Run `git tag -a v0.3.0 -m "0.3.0"`, push the tag, and run `gh release create v0.3.0 --title 0.3.0 --notes-file <section>`. Watch the `Deploy release` workflow and check `https://acervo-app.fly.dev/health`.
- [ ] **Step 4: Production smoke test.**
  - Save a blog post, a YouTube video, an X post and an Instagram post.
  - Check the cards and images.
  - Add a link to a collection.
  - Add a screenshot to a link whose capture failed.
  - Report the per-source results to the owner. Instagram and X are best-effort, and the screenshot fallback covers them.
