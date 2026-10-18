defmodule AcervoWeb.GuideComponents do
  @moduledoc """
  The in-app guide shown at `/guide`: every feature and keyboard shortcut,
  briefly. Keep it in step with `guides/features.md`.
  """
  use Phoenix.Component
  use Gettext, backend: AcervoWeb.Gettext

  import AcervoWeb.ArchiveComponents, only: [mod_key: 1]
  import AcervoWeb.CoreComponents

  @doc "Renders the guide's sections and its shortcuts table."
  def guide(assigns) do
    ~H"""
    <div id="guide" class="guide">
      <p class="desc">{gettext("What Acervo does, in brief.")}</p>

      <.guide_section id="guide-save" title={gettext("Save")}>
        <:row icon="lucide-link">
          {gettext("Paste a link anywhere. It must start with http(s):// or www.")}
        </:row>
        <:row icon="lucide-plus">{gettext("Or tap + in the dock, paste and press ↩.")}</:row>
        <:row icon="lucide-inbox">
          {gettext("It lands in the Inbox while its preview loads in the background.")}
        </:row>
        <:row icon="lucide-corner-down-right">
          {gettext("Saving it again opens the one you already have.")}
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
        <:row icon="lucide-ellipsis">
          {gettext("Rename, describe or delete a collection. Its links stay.")}
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
            <tr>
              <td><kbd>↩</kbd></td>
              <td>{gettext("In the add field: save")}</td>
            </tr>
            <tr>
              <td><kbd>Esc</kbd></td>
              <td>{gettext("Close the add field or a menu")}</td>
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
