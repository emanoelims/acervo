# Features and shortcuts

Everything Acervo does for its user, and where each piece lives. The in-app
guide at `/guide` (`AcervoWeb.ArchiveLive`, live action `:guide`, content in
`AcervoWeb.GuideComponents`) says the same thing to the user. When a
user-facing feature or keyboard shortcut changes, update both in the same PR.

The archive is one LiveView, `AcervoWeb.ArchiveLive`. Its columns, dock and
popovers come from `AcervoWeb.ArchiveComponents`. The open link's column comes
from `AcervoWeb.LinkComponents`. Hooks are colocated with the markup that
uses them. Their names start with a dot.

## Save

- **Paste anywhere.** Paste a link while no field has focus to save it. Only
  text that starts with `http://`, `https://` or `www.` counts. The `.Shortcuts`
  hook on `#columns` in `ArchiveLive` pushes `add_link`.
- **Dock +.** The dock's **+** (`#dock-add`) opens the add pill (`add_pill/1`,
  `#add-link-form`). Press ↩ to save. The pill also accepts bare hosts.
- **Inbox first.** New links land in the inbox (`Acervo.Library.save_link/2`).
  `Acervo.Library.CaptureLink` (Oban) captures the preview in the background,
  through `Acervo.Library.Capture` and the extractors in
  `lib/acervo/library/extractors/`.
- **Duplicates.** Saving a link you already have opens the existing one:
  `save_link/2` returns `:existing`.

## Previews and screenshots

- **Cards.** Web pages, YouTube, X and Instagram each get a card:
  `LinkComponents.card/1` and `link_detail/1`.
- **Screenshots.** When capture fails (`capture_error`, often on Instagram),
  the open link shows a drop zone (`#screenshot-drop`). Drop or pick an image,
  or use the camera action (`#link-screenshot`). You can also paste an image
  while the link is open: the `.ScreenshotPaste` hook in `LinkComponents`
  handles it. `Acervo.Library.attach_screenshot/3` stores the image.

## Read

- **Web view column.** Clicking the open link's image (`#link-web-toggle`), or
  the globe action (`#link-web`) on links without one, patches to
  `…/l/:id/web` and opens one more column (`#column-web`, `web_view/1` in
  `LinkComponents`). Clicking it again, the ✕ (`#web-close`) or Esc closes it.
  The ↗ (`#web-open`) opens the original in a new tab.
- **What it shows.** YouTube, X and Instagram use their official embeds. Other
  pages are framed when they allow it, over https only. The frame is
  sandboxed and sends no referrer (YouTube gets the app's origin, which its
  player requires). `Acervo.Library.Embed` decides what to frame.
- **Embeddability.** Capture reads the page's `X-Frame-Options` and CSP
  `frame-ancestors` headers (`Acervo.Library.FramePolicy`) into the link's
  `embeddable`. Links captured before that are checked once when the column
  opens (`Acervo.Library.check_embeddable/2`, run with `start_async`).
- **Reader view.** Pages that can't be framed, or whose check failed, show the
  page's article (`#web-reader-content`, a `.reader` at most 680px wide). A
  framed page with an article gets a head button (`#web-reader-toggle`,
  book ⇄ globe) that patches to `?view=reader` and back, so a reload keeps it.
  Without an article, the column falls back to the captured text
  (`#web-reader-text`) with a faint hint and an “Open original” button.
- **Article capture.** For web pages, capture keeps the article as sanitized
  HTML in `content_html` (`Acervo.Library.Reader`). It first looks for a
  Markdown version (`Acervo.Library.MarkdownSource`): a
  `<link rel="alternate" type="text/markdown">`, the URL with `.md`, or a
  matching `.md` in the site's `/llms.txt`, at most three requests of 1 MB.
  Markdown is rendered by MDEx with raw HTML escaped; otherwise
  `Acervo.Library.Article` picks the longest `article`/`main` block, or the
  element with the most paragraph text, and drops navigation, sharing,
  comments and signup blocks. Either way `Acervo.Library.Sanitizer` rebuilds
  it from an allowlist of tags and attributes, links open in a new tab, and
  the output stops before 300 KB. A faint “Markdown” marks articles that came
  from Markdown. Up to 20 inline images are downloaded through `SafeFetch`,
  stored as WebP link images of kind `:content` and served from
  `/images/:id`. YouTube, X and Instagram keep their embeds. Links captured
  before this get their article from a one-off backfill
  (`Acervo.Release.backfill_reader_content/0`, see the deployment guide).

## Organize

- **Collections popover.** The folder-plus action on a link (`#link-collections`,
  `collection_picker/1` in `LinkComponents`) works three ways:
  - type to filter;
  - click a collection to add or remove the link;
  - type a new name and pick “name” to create the collection and add the link.
- **Chips.** The ✕ on a collection chip (`#chip-remove-*`) removes the link
  from that collection.
- **Column 1.** The collections are listed in column 1, and its **+**
  (`#new-collection`) creates one.
- **Collection ··· menu.** The menu (`collection_menu/1` in
  `ArchiveComponents`) renames, describes or deletes the collection. Deleting
  keeps its links. Business rules live in `Acervo.Collections`.

## Inbox

- **Cards.** On `/inbox` each card is wrapped by `LinkComponents.inbox_item/1`
  (the stream id `#link-<id>` moves to the wrapper, the card becomes
  `#card-<id>`), which adds a triage bar (`.ibar`) inside the same surface:
  the link's collections as filled chips and its pending suggestions as
  dashed ones, at most three chips, then the actions.
- **Suggestions.** Each saved link is read by Claude in the background (see
  Enrichment below), which suggests up to three collections: one of yours
  (✦) or a new name (+). The reason is the chip's tooltip on cards, and a
  faint line beside it in the link column. Suggestions never apply on their
  own.
- **Accepting.** Click a chip (`#suggestion-<id>` on cards,
  `#link-suggestion-accept-<id>` in the link column) to add the link to that
  collection, creating it for a new name (`Collections.accept_suggestion/2`).
  It becomes a filled chip. Pending suggestions with the same new name on
  other links are repointed to the collection just created.
- **Dismissing.** The ✕ on a suggestion in the link column
  (`#suggestion-dismiss-<id>`) dismisses it; it is never suggested again for
  that link.
- **Accept all.** With two or more suggestions, the double check
  (`#accept-all-<link>` on cards, `#link-accept-all` in the link column)
  accepts them all and finishes the link
  (`Collections.accept_all_suggestions/2`).
- **Done.** ✓ (`#done-<link>` on cards, `#link-done` in the link column)
  finishes the link (`Collections.finish_triage/2`): its leftover
  suggestions are dismissed and it leaves the inbox, sliding out
  (`phx-remove` on the wrapper). If it was open, its column closes.
- **While reading.** While enrichment is `:pending`, a faint dashed chip with
  a shimmer (`.chip.ai.is-waiting`) holds the row, so nothing jumps when the
  suggestions land through `{:link_updated, link}`. A failed or skipped
  enrichment shows no chips; ✓ still works.

## Enrichment

- **Worker.** `Acervo.AI.EnrichLink` (Oban, queue `ai`) runs after a capture,
  after reader content is extracted, and again when a screenshot is attached.
  One Claude call per link (`Acervo.AI.Enrichment`) gets the page's title,
  description, site, article text, first image and the user's collections
  (up to 50, with three example titles each).
- **Output.** An image description, the page's language and 1–3 collection
  suggestions with short reasons, stored as `collection_suggestions`.
  Triaged links get no new suggestions.
- **Untrusted content.** Everything captured from the web goes into the
  prompt as one JSON data block inside a random per-call delimiter, which the
  system prompt says is data, never instructions. The output is validated:
  unknown collection slugs are dropped, lengths are clamped and control
  characters stripped.
- **Image description.** Shown in the link column under the page
  description, with a faint ✦ (`#image-description-form`,
  `#link-image-description`). Edit it like the note: it saves on blur or
  ⌘↩ (Ctrl+↩), shows a brief “Saved” in `#image-description-status`, and
  `Library.update_image_description/3` stamps `image_description_edited_at`
  so enrichment never overwrites it.
- **Failures.** Rate limits snooze, transient errors retry, and the last
  attempt marks the link `:failed`. A failure never blocks triage.
- **Costs.** Every call's tokens and estimated cost go to `ai_calls`;
  `Acervo.Release.ai_costs/1` reports them per day.

## Notes

- **Saving.** A note saves when you leave the field (`phx-blur`) or press
  ⌘↩ on macOS (Ctrl+↩ elsewhere). The `.SubmitShortcut` hook on `#link-note`
  submits `#note-form`; the image description uses the same hook. Enter alone
  inserts a newline.
- **Hint.** A faint hint below the note (`#note-hint`) shows the shortcut
  while the note is focused.
- **Saved status.** After a save that changed the note, a brief “Saved”
  status appears in `#note-status` (`role="status"`). `ArchiveLive` clears it
  after 1.5 s with `{:clear_saved, :note_saved, ref}`. A save that changes nothing
  shows nothing.

## Appearance and language

- **Dock settings.** The settings popover (`#dock-settings`, `dock/1` and
  `appearance_panel/1` in `ArchiveComponents`) holds:
  - theme, accent and font, saved per browser by `assets/js/appearance.js`;
  - PT/EN, through `AcervoWeb.LocaleController`;
  - “Shortcuts and features” (`#dock-guide`), which opens the guide;
  - log out.

## Keyboard shortcuts

⌘ on macOS, Ctrl elsewhere. `assets/js/app.js` sets `<html data-platform>`.
CSS uses it to show the matching labels (`mod_key/1` in `ArchiveComponents`),
and hooks use it to pick the modifier key.

| Keys         | Where             | Does                                 | Implemented in                        |
| ------------ | ----------------- | ------------------------------------ | ------------------------------------- |
| ⌘/Ctrl V     | anywhere          | saves a copied link                  | `.Shortcuts` (`ArchiveLive`)          |
| ⌘/Ctrl V     | with a link open  | adds a copied image as a screenshot  | `.ScreenshotPaste` (`LinkComponents`) |
| ↩            | add pill          | saves the link                       | `#add-link-form` submit               |
| Esc          | add pill, popover | closes it                            | `close_add`; `assets/js/floating.js`  |
| Esc          | page column open  | closes the page column               | `.Shortcuts` → `close_web` event      |
| ⌘/Ctrl ↩     | note, description | saves the field                      | `.SubmitShortcut` (`LinkComponents`)  |
| ?            | outside fields    | opens the guide (`/guide`)           | `.Shortcuts` → `open_guide` event     |

Page-wide keys do nothing while you type in an input, a textarea or a
contenteditable element. The `?` key also does nothing when Ctrl, ⌘ or Alt is
held. Esc closes the add pill or an open popover before the page column, and
does nothing while focus is inside the framed page.
