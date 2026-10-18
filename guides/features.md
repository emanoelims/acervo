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
  captured text (`#web-reader`) with a faint hint and an “Open original”
  button.

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

- **Done.** ✓ (`#link-done`) marks the link as triaged
  (`Acervo.Library.mark_triaged/2`). That removes it from the inbox.

## Notes

- **Saving.** A note saves when you leave the field (`phx-blur`) or press
  ⌘↩ on macOS (Ctrl+↩ elsewhere). The `.NoteShortcut` hook on `#link-note`
  submits `#note-form`. Enter alone inserts a newline.
- **Hint.** A faint hint below the note (`#note-hint`) shows the shortcut
  while the note is focused.
- **Saved status.** After a save that changed the note, a brief “Saved”
  status appears in `#note-status` (`role="status"`). `ArchiveLive` clears it
  after 1.5 s with `{:clear_note_saved, ref}`. A save that changes nothing
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
| ⌘/Ctrl ↩     | in a note         | saves the note                       | `.NoteShortcut` (`LinkComponents`)    |
| ?            | outside fields    | opens the guide (`/guide`)           | `.Shortcuts` → `open_guide` event     |

Page-wide keys do nothing while you type in an input, a textarea or a
contenteditable element. The `?` key also does nothing when Ctrl, ⌘ or Alt is
held. Esc closes the add pill or an open popover before the page column, and
does nothing while focus is inside the framed page.
