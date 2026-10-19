defmodule AcervoWeb.GuideComponents do
  @moduledoc """
  The in-app guide shown at `/guide`: every feature and keyboard shortcut,
  briefly. Keep it in step with `guides/features.md`.
  """
  use Phoenix.Component
  use Gettext, backend: AcervoWeb.Gettext

  import AcervoWeb.CoreComponents
  import AcervoWeb.UIComponents, only: [mod_key: 1]

  @doc "Renders the guide's sections and its shortcuts table."
  attr :snapshots, :boolean, default: false, doc: "the screenshot service is on"

  def guide(assigns) do
    ~H"""
    <div id="guide" class="guide">
      <p class="desc">{gettext("What Acervo does, in brief.")}</p>

      <.guide_section id="guide-save" title={gettext("Save")}>
        <:row icon="lucide-link">
          {gettext("Paste a link anywhere. It must start with http(s):// or www.")}
        </:row>
        <:row icon="lucide-plus">{gettext("Or tap + in the dock, paste and press ↩.")}</:row>
        <:row icon="lucide-list">
          {gettext("Paste a list, or text with several links, to save them all at once.")}
        </:row>
        <:row icon="lucide-inbox">
          {gettext("It lands in the Inbox while its preview loads in the background.")}
        </:row>
        <:row icon="lucide-corner-down-right">
          {gettext("Saving it again opens the one you already have.")}
        </:row>
      </.guide_section>

      <.guide_section id="guide-import" title={gettext("Import bookmarks")}>
        <:row icon="lucide-bookmark-plus">
          {gettext("In the dock settings: bring your browser's bookmarks, exported as HTML.")}
        </:row>
        <:row icon="lucide-folder">
          {gettext(
            "Each folder becomes a collection, goes to the Inbox or is skipped. You choose before importing."
          )}
        </:row>
        <:row icon="lucide-sparkle">
          {gettext("The estimated AI cost shows first. Links you already have aren't saved twice.")}
        </:row>
        <:row icon="lucide-circle-stop">
          {gettext("It runs in the background, even with the page closed. Stop it anytime.")}
        </:row>
      </.guide_section>

      <.guide_section id="guide-search" title={gettext("Search")}>
        <:row icon="lucide-search">
          {gettext("Describe what you remember: words, what the image shows, your note.")}
        </:row>
        <:row icon="lucide-folder">
          {gettext("Inside a collection, search looks only there. ✕ widens it.")}
        </:row>
        <:row icon="lucide-zap-off">
          {gettext("This icon means only matching words were found this time.")}
        </:row>
      </.guide_section>

      <.guide_section id="guide-previews" title={gettext("Previews and screenshots")}>
        <:row icon="lucide-layout-grid">
          {gettext("Cards for web pages, YouTube, X and Instagram.")}
        </:row>
        <:row icon="lucide-camera">
          {gettext(
            "No preview (Instagram often blocks it)? Drop, pick or paste a screenshot while the link is open."
          )}
        </:row>
        <:row :if={@snapshots} icon="lucide-refresh-cw">
          {gettext(
            "Pages without a preview get a picture of their first screen. The camera makes a new one."
          )}
        </:row>
        <:row icon="lucide-sparkle">
          {gettext("Claude describes each link's image; edit the description if it's wrong.")}
        </:row>
      </.guide_section>

      <.guide_section id="guide-web" title={gettext("Read")}>
        <:row icon="lucide-globe">
          {gettext("Click a link's image, or the globe, to open its page in a new column.")}
        </:row>
        <:row icon="lucide-book-open">
          {gettext(
            "Acervo keeps each page's article, with images, so sites that can't be shown there, or are offline, open as a reader view. Switch between page and reader at the top."
          )}
        </:row>
      </.guide_section>

      <.guide_section id="guide-organize" title={gettext("Organize")}>
        <:row icon="lucide-folder-plus">
          {gettext("On a link: filter collections, tap to toggle, or type a new name to create one.")}
        </:row>
        <:row icon="lucide-x">{gettext("On a chip: take the link out of that collection.")}</:row>
        <:row icon="lucide-folder">
          {gettext("Collections live in the first column; + creates one.")}
        </:row>
        <:row icon="lucide-house">
          {gettext("The home shows the Inbox and each collection side by side, newest links first.")}
        </:row>
        <:row icon="lucide-ellipsis">
          {gettext("Rename, describe or delete a collection. Its links stay.")}
        </:row>
      </.guide_section>

      <.guide_section id="guide-related" title={gettext("Related")}>
        <:row icon="lucide-link">
          {gettext("On a link: connect another one by hand. ✕ on its card disconnects them.")}
        </:row>
        <:row icon="lucide-search">
          {gettext("Similar links show up below on their own. See more similar lists them all.")}
        </:row>
      </.guide_section>

      <.guide_section id="guide-inbox" title={gettext("Inbox")}>
        <:row icon="lucide-sparkle">
          {gettext("Suggested collections: tap one to add the link. + marks a new one.")}
        </:row>
        <:row icon="lucide-check-check">
          {gettext("Accept all adds every suggestion and finishes.")}
        </:row>
        <:row icon="lucide-check">
          {gettext("Done finishes the link and dismisses the rest.")}
        </:row>
      </.guide_section>

      <.guide_section id="guide-notes" title={gettext("Notes")}>
        <:row icon="lucide-notebook-pen">
          <span class="key-mac">{gettext(
            "A note, or an image description, saves with %{keys} or when you leave the field.",
            keys: "⌘↩"
          )}</span>
          <span class="key-other">
            {gettext(
              "A note, or an image description, saves with %{keys} or when you leave the field.",
              keys: "Ctrl+↩"
            )}
          </span>
        </:row>
        <:row icon="lucide-sparkle">
          {gettext(
            "Generate notes asks Claude for a summary and key points. Edit them like your note."
          )}
        </:row>
        <:row icon="lucide-settings-2">
          {gettext("Automatic notes, in the dock settings: never, for long articles or always.")}
        </:row>
      </.guide_section>

      <.guide_section id="guide-appearance" title={gettext("Appearance and language")}>
        <:row icon="lucide-settings-2">
          {gettext("In the dock settings: theme, accent, font and PT/EN.")}
        </:row>
      </.guide_section>

      <section id="guide-shortcuts" class="guide-section">
        <h3 class="guide-head">{gettext("Shortcuts")}</h3>
        <table class="guide-keys">
          <tbody>
            <tr>
              <td><kbd><.mod_key /></kbd><kbd>V</kbd></td>
              <td>{gettext("Save a copied link")}</td>
            </tr>
            <tr>
              <td><kbd><.mod_key /></kbd><kbd>V</kbd></td>
              <td>{gettext("With a link open: add a copied image")}</td>
            </tr>
            <tr id="guide-key-search">
              <td><kbd>/</kbd></td>
              <td>{gettext("Search")}</td>
            </tr>
            <tr id="guide-key-search-anywhere">
              <td><kbd><.mod_key /></kbd><kbd>K</kbd></td>
              <td>{gettext("Search, from anywhere")}</td>
            </tr>
            <tr>
              <td><kbd>↩</kbd></td>
              <td>{gettext("In the add field: save")}</td>
            </tr>
            <tr>
              <td><kbd>Esc</kbd></td>
              <td>{gettext("Close the add field, the search field or a menu")}</td>
            </tr>
            <tr>
              <td><kbd>Esc</kbd></td>
              <td>{gettext("Close the page column")}</td>
            </tr>
            <tr>
              <td><kbd><.mod_key /></kbd><kbd>↩</kbd></td>
              <td>{gettext("In a note or description: save it")}</td>
            </tr>
            <tr>
              <td><kbd>?</kbd></td>
              <td>{gettext("Open this guide")}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true

  slot :row, required: true do
    attr :icon, :string, required: true
  end

  defp guide_section(assigns) do
    ~H"""
    <section id={@id} class="guide-section">
      <h3 class="guide-head">{@title}</h3>
      <ul class="guide-list">
        <li :for={row <- @row} class="guide-row">
          <.icon name={row.icon} class="guide-glyph size-4" /><span>{render_slot(row)}</span>
        </li>
      </ul>
    </section>
    """
  end
end
