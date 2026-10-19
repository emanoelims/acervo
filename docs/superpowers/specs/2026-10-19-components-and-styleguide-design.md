# Components and the styleguide

Date: 2026-10-19 · Status: approved

Acervo's UI grew screen by screen, so the same pieces (round icon buttons,
chips, drop zones, column headers) were written inline in several places and
presentation logic lived inside components. This spec sorts the UI into
reusable function components, moves pure logic into plain modules with unit
tests, and adds a development-only styleguide page that renders every piece.

## Conventions followed

From Phoenix 1.8's generated `core_components.ex` and `Phoenix.Component`:

- Function components first. Each public component has an `@doc` with a usage
  example and declares its `attr`s (type, `:values`, `:default`, `:doc`) and
  `slot`s, so the compiler checks every call.
- `attr :rest, :global, include: ~w(...)` passes `id`, `phx-*`, `aria-*` and
  link attributes through; `attr :class, :any` is merged with list syntax
  (`class={["base", @variant && "...", @class]}`).
- One component dispatches on its input, as `input/1` does on `type` and
  `button/1` on `href`/`navigate`/`patch`: a button, a link or a label from the
  same component.
- `<.icon>` for every icon; `Phoenix.LiveView.JS` for client-only state.
- Colocated hooks stay in the component that needs them.
- A LiveComponent only when a piece owns both state and events that would
  otherwise spill into its parent (`Phoenix.LiveComponent`: "prefer function
  components"; AGENTS.md: "avoid LiveComponents unless you have a strong need").

## Inventory

| Piece | Before | After |
| --- | --- | --- |
| popover, dropdown_item, flash, button, input, icon | `CoreComponents` | stays; `dropdown_item/1` also renders a `<button>` when it has no `navigate`/`href` |
| column (with `.ColumnScroll` hook), nav_item, empty, mod_key | `ArchiveComponents` | `UIComponents` |
| column header | inline in `column/1` and the root column | `UIComponents.column_head/1` |
| round / head / plain icon buttons (`.round`, `.round-sm`, `.head-button`, `.icon-button`) | inline in archive_live, link_components, import_component | `UIComponents.icon_button/1` |
| pill button (`.pill-button`) | inline in web view | `UIComponents.pill_button/1` |
| chips (`.chip`, `.chip-sm`, `.ai`, `.chip-x`), waiting chip | inline + private | `UIComponents.chip/1`, `chip_remove/1`, `waiting_chip/1` |
| nav "+" (`.nav-add`) | inline in archive_live | `UIComponents.nav_add/1` |
| floating pill shell (`.float`) | duplicated in add and search pills | `UIComponents.float_pill/1` |
| drop zone (`.shot-drop`) | duplicated in link detail and import | `UIComponents.drop_zone/1` |
| dock, add_pill, search_pill, collection_menu, appearance_panel | `ArchiveComponents` | stay (domain), composed from primitives |
| card, inbox_item, link_detail, web_view, source_icon | `LinkComponents` | stay (domain), composed from primitives |
| guide | `GuideComponents` | stays |

Module roles:

- `AcervoWeb.CoreComponents`: the generator's foundations, kept close to the
  Phoenix template so upgrades stay easy to diff.
- `AcervoWeb.UIComponents`: Acervo's own design-system primitives, imported
  everywhere through `html_helpers/0`. Like `ArchiveComponents`, it does not
  `use AcervoWeb, :html` (it would import itself).
- Domain modules (`ArchiveComponents`, `LinkComponents`, `GuideComponents`)
  compose primitives; their private helpers stay private.

## Logic moved out of components

- `AcervoWeb.Format`: locale-aware `date/1` (was `format_date/1`), `number/1`,
  `usd/1` and `duration/1` (were private in `ImportComponent`).
- `AcervoWeb.LinkPresenter`: `display_title/1`, `site_title/1`, `host/1`,
  `link_date/1`, `kind/1`, `first_image/1`, `image_src/1`, `meta/1`,
  `suggestion_name/1`, `paragraphs/1` (reader text) and `collection_choices/2`
  (the collection picker's filter, create and "C++" rules).

`LinkComponents` keeps `display_title/1`, `site_title/1`, `host/1`,
`link_date/1` and `format_date/1` as delegates, so callers don't change.
`image_src/1` returns `/images/:id`, or an image's own `src` when it has one,
which lets the styleguide show cards without the database.

## LiveComponents

`AcervoWeb.ImportComponent` stays a LiveComponent. It owns an upload
(`allow_upload`), the parsed file, per-folder choices and totals, five events
and progress pushed by `send_update/3`. As function components, all of that
would move into `ArchiveLive`, which already holds the browser's state. Its
formatting moves to `AcervoWeb.Format` and its markup uses the primitives.
No other LiveComponent is needed.

## Styleguide

- `/dev/styleguide`, a LiveView in the `dev_routes` scope, so it exists only
  where `config :acervo, dev_routes: true` (dev and test). Its modules live in
  `dev/`, compiled only in dev and test (`elixirc_paths`), so production
  neither routes to it nor compiles it.
- No user and no database: links, collections, suggestions and images are
  in-memory structs; images are inline SVG data URIs. Clicks show their event
  in a flash instead of running it.
- Page: a slim header with theme, accent and font switches (setting
  `data-theme`, `data-accent` and `data-font` on `<html>`, without saving the
  preference), then sections: tokens (color swatches, type scale, radii and
  shadows, fonts, icons), primitives (buttons, chips, navigation, columns,
  popover and menu, inputs, floating pill, drop zone, flash, empty and
  skeleton), and domain pieces (cards of every kind, inbox item, link detail,
  dock) inside a real `.columns` row. Each section names the component and
  shows a one-line usage snippet.
- Its own styles are colocated CSS in the LiveView, so nothing ships to
  production.

## Follow-ups

- `link_detail/1`'s action row and screenshot drop zone still use inline
  markup; switch them to `icon_button/1` and `drop_zone/1` once the concurrent
  link-detail work lands, to avoid conflicting edits.
