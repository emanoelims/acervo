defmodule AcervoWeb.LinkComponents do
  @moduledoc "Link cards, the link column and source marks (approved prototype, option A)."
  # Mirrors `AcervoWeb.ArchiveComponents`: kept free of `use AcervoWeb, :html`
  # so it can join `html_helpers/0` later without importing itself.
  use Phoenix.Component
  use Gettext, backend: AcervoWeb.Gettext
  use AcervoWeb, :verified_routes

  import AcervoWeb.CoreComponents

  import AcervoWeb.LinkPresenter,
    only: [kind: 1, first_image: 1, image_src: 1, meta: 1, suggestion_name: 1, paragraphs: 1, collection_choices: 2]

  import AcervoWeb.UIComponents

  alias Acervo.Library.Embed
  alias AcervoWeb.Format
  alias AcervoWeb.LinkPresenter
  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @ibar_chips 3

  @doc """
  Renders a link card that patches to the link. The kind follows the link:
  a skeleton while capturing, a thumbnail for YouTube, the image over a
  blurred copy of itself, or text. Images, thumbnails and the skeleton share
  one 16:10 shape.
  """
  attr :id, :string, required: true
  attr :link, :map, required: true
  attr :patch, :string, required: true
  attr :selected, :boolean, default: false

  def card(assigns) do
    assigns = assign(assigns, kind: kind(assigns.link), image: first_image(assigns.link))

    ~H"""
    <.link
      id={@id}
      patch={@patch}
      class={[
        "card",
        @kind != :text && "card-#{@kind}",
        @kind == :text && "text",
        @selected && "is-selected"
      ]}
      aria-current={@selected && "true"}
    >
      <.source_icon source={@link.source} />
      <%= case @kind do %>
        <% :pending -> %>
          <div class="pad pad-head">
            <div class="date">{format_date(link_date(@link))}</div>
            <div class="ttl">{host(@link)}</div>
          </div>
          <div class="media skeleton" aria-hidden="true"></div>
        <% :video -> %>
          <div class="pad pad-head">
            <div class="date">{format_date(link_date(@link))}</div>
            <div class="ttl">{display_title(@link)}</div>
          </div>
          <.video_media image={@image} />
        <% :image -> %>
          <.glow image={@image} alt={@link.title} />
          <div :if={@link.source == :generic and is_binary(@link.title)} class="pad pad-under">
            <div class="ttl">{@link.title}</div>
            <div :if={@link.description} class="sub">{@link.description}</div>
          </div>
        <% :text -> %>
          <div class="pad">
            <div class="date">{format_date(link_date(@link))}</div>
            <div class="ttl">{display_title(@link)}</div>
            <div :if={@link.description} class="sub">{@link.description}</div>
            <span
              :if={@link.capture_error}
              class="card-shot"
              title={gettext("Add a screenshot")}
              aria-label={gettext("Add a screenshot")}
            >
              <.icon name="lucide-camera" class="size-[15px]" />
            </span>
          </div>
      <% end %>
    </.link>
    """
  end

  @doc """
  Renders an inbox card: the link's `card/1` and, under it in the same
  surface, its triage bar. The bar shows the link's collections (filled) and
  pending suggestions (dashed, accepted by a click), at most #{@ibar_chips}
  chips, a quiet placeholder while enrichment runs, "accept all" when two or
  more are pending, and ✓.

  `card/1` is a link, so the bar's buttons can't nest in it: the stream DOM
  id goes on this wrapper and the card takes a derived id.
  """
  attr :id, :string, required: true
  attr :link, :map, required: true
  attr :patch, :string, required: true
  attr :selected, :boolean, default: false

  def inbox_item(assigns) do
    suggestions = Enum.take(assigns.link.suggestions, @ibar_chips)
    collections = Enum.take(assigns.link.collections, @ibar_chips - length(suggestions))

    assigns =
      assign(assigns,
        suggestions: suggestions,
        collections: collections,
        waiting?: assigns.link.enrichment_status == :pending and suggestions == []
      )

    ~H"""
    <div id={@id} class="inbox-item" phx-remove={JS.transition("is-leaving", time: 380)}>
      <.card id={"card-#{@link.id}"} link={@link} patch={@patch} selected={@selected} />
      <div class="ibar">
        <div class="ibar-chips">
          <.chip
            :for={collection <- @collections}
            id={"card-chip-#{@link.id}-#{collection.id}"}
            size="sm"
          >
            {collection.name}
          </.chip>
          <.suggestion_button
            :for={suggestion <- @suggestions}
            id={"suggestion-#{suggestion.id}"}
            suggestion={suggestion}
            class="chip chip-sm ai"
          />
          <.waiting_chip :if={@waiting?} size="sm" />
        </div>
        <div class="ibar-acts">
          <.icon_button
            :if={length(@link.suggestions) > 1}
            id={"accept-all-#{@link.id}"}
            size="sm"
            icon="lucide-check-check"
            label={gettext("Accept all and finish")}
            phx-click="accept_all"
            phx-value-id={@link.id}
          />
          <.icon_button
            id={"done-#{@link.id}"}
            size="sm"
            icon="lucide-check"
            label={gettext("Done")}
            phx-click="finish"
            phx-value-id={@link.id}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :suggestion, :map, required: true
  attr :class, :string, required: true

  # A suggested collection: ✦ and the name of one of the user's collections,
  # or + and a new name. Clicking accepts it; the reason is its tooltip.
  defp suggestion_button(assigns) do
    assigns = assign(assigns, :name, suggestion_name(assigns.suggestion))

    ~H"""
    <button
      id={@id}
      type="button"
      class={@class}
      phx-click="accept_suggestion"
      phx-value-id={@suggestion.id}
      title={@suggestion.reason}
      aria-label={gettext("Add to %{name}", name: @name)}
    >
      <.suggestion_glyph suggestion={@suggestion} /><span class="chip-name">{@name}</span>
    </button>
    """
  end

  attr :suggestion, :map, required: true

  defp suggestion_glyph(%{suggestion: %{collection_id: nil}} = assigns) do
    ~H"""
    <.icon name="lucide-plus" class="chip-glyph size-3" />
    """
  end

  defp suggestion_glyph(assigns) do
    ~H"""
    <.icon name="lucide-sparkle" class="chip-glyph size-[11px]" />
    """
  end

  @doc """
  Renders the open link: its visual (every image stacked, the first one in the
  glow treatment), meta line, collections and pending suggestions (each with
  its reason), the page description, the editable image description, the
  note and actions.
  The visual, or the globe action when there is no image, patches to
  `web_path`, which opens or closes the web view column. With `snapshots`,
  the camera action opens a menu that also generates a new image.
  """
  attr :link, :map, required: true
  attr :note_form, Form, required: true
  attr :collections, :list, required: true, doc: "every collection of the user, for the picker"
  attr :collection_filter, Form, required: true
  attr :upload, :map, required: true, doc: "the `:screenshot` upload config"
  attr :note_saved, :boolean, default: false, doc: "shows the brief “Saved” status after a note save"
  attr :description_form, Form, required: true, doc: "the image description form"
  attr :description_saved, :boolean, default: false, doc: "the same status after an image description save"
  attr :web_path, :string, required: true, doc: "opens the web view column, or closes it when `web_open`"
  attr :web_open, :boolean, default: false
  attr :snapshots, :boolean, default: false, doc: "the screenshot service is on: the camera opens the image menu"
  attr :snapshot_busy, :boolean, default: false, doc: "a requested snapshot of the link is running"

  def link_detail(assigns) do
    images = assigns.link.images

    assigns =
      assign(assigns,
        kind: kind(assigns.link),
        drop?: images == [] or is_binary(assigns.link.capture_error) or assigns.upload.entries != [],
        image: List.first(images),
        more_images: Enum.drop(images, 1),
        meta: meta(assigns.link),
        waiting?: assigns.link.enrichment_status == :pending and assigns.link.suggestions == []
      )

    ~H"""
    <div id="link-detail" class="link-detail">
      <div class="link-visual">
        <%= case @kind do %>
          <% :pending -> %>
            <div class="card card-static">
              <.source_icon source={@link.source} />
              <div class="media skeleton" aria-hidden="true"></div>
            </div>
          <% :video -> %>
            <.web_toggle path={@web_path} open={@web_open}>
              <div class="card card-static">
                <.source_icon source={@link.source} />
                <.video_media image={@image} />
              </div>
            </.web_toggle>
          <% :image -> %>
            <.web_toggle path={@web_path} open={@web_open}>
              <div class="card card-static">
                <.source_icon source={@link.source} />
                <.glow image={@image} alt={@link.title} />
              </div>
            </.web_toggle>
            <img
              :for={image <- @more_images}
              id={"link-image-#{image.id}"}
              class="stack-img"
              src={image_src(image)}
              width={image.width}
              height={image.height}
              alt=""
              loading="lazy"
            />
          <% :text -> %>
            <div class="card card-static text">
              <.source_icon source={@link.source} />
              <div class="pad">
                <div class="date">{format_date(link_date(@link))}</div>
                <div class="ttl">{display_title(@link)}</div>
                <div :if={@link.description} class="sub">{@link.description}</div>
              </div>
            </div>
        <% end %>
      </div>

      <.form
        for={%{}}
        id="screenshot-form"
        phx-change="validate_screenshot"
        phx-hook=".ScreenshotPaste"
      >
        <.live_file_input upload={@upload} class="sr-only" tabindex="-1" />
        <label
          :if={@drop?}
          id="screenshot-drop"
          for={@upload.ref}
          class={["shot-drop", @upload.entries != [] && "is-busy"]}
          phx-drop-target={@upload.ref}
        >
          <.icon name="lucide-camera" class="size-[18px]" />
          <span class="shot-hint">{gettext("Drop or paste a screenshot")}</span>
          <span :for={entry <- @upload.entries} class="shot-bar" aria-hidden="true">
            <i style={"width: #{entry.progress}%"}></i>
          </span>
          <span
            :for={
              error <-
                upload_errors(@upload) ++ Enum.flat_map(@upload.entries, &upload_errors(@upload, &1))
            }
            id="screenshot-error"
            class="shot-error"
            role="alert"
          >
            {upload_error(error)}
          </span>
        </label>
      </.form>

      <p class="meta">{@meta}</p>

      <div :if={@link.collections != [] or @waiting?} class="chips">
        <.chip :for={collection <- @link.collections} id={"link-chip-#{collection.id}"}>
          <.link patch={~p"/c/#{collection.slug}"} class="chip-link">
            <.icon name="lucide-folder" class="size-[13px]" />{collection.name}
          </.link>
          <.chip_remove
            id={"chip-remove-#{collection.id}"}
            label={gettext("Remove from collection")}
            phx-click="remove_from_collection"
            phx-value-id={collection.id}
          />
        </.chip>
        <.waiting_chip :if={@waiting?} />
      </div>

      <ul :if={@link.suggestions != []} id="link-suggestions" class="sugs">
        <li :for={suggestion <- @link.suggestions} class="sug">
          <.chip id={"link-suggestion-#{suggestion.id}"} ai>
            <.suggestion_button
              id={"link-suggestion-accept-#{suggestion.id}"}
              suggestion={suggestion}
              class="chip-link"
            />
            <.chip_remove
              id={"suggestion-dismiss-#{suggestion.id}"}
              title={gettext("Dismiss")}
              label={gettext("Dismiss %{name}", name: suggestion_name(suggestion))}
              phx-click="dismiss_suggestion"
              phx-value-id={suggestion.id}
            />
          </.chip>
          <span :if={suggestion.reason} class="sug-why">{suggestion.reason}</span>
        </li>
      </ul>

      <div class="link-notes">
        <p :if={@kind != :text and is_binary(@link.description)} class="ai">{@link.description}</p>
        <div :if={@link.images != []} class="edit edit-image">
          <.form
            for={@description_form}
            id="image-description-form"
            class="note"
            phx-submit="save_image_description"
          >
            <.icon name="lucide-sparkle" class="edit-glyph size-[11px]" />
            <.input
              type="textarea"
              field={@description_form[:image_description]}
              id="link-image-description"
              class="note-input image-input"
              rows="1"
              maxlength="1000"
              placeholder={gettext("Describe the image")}
              aria-label={gettext("Image description")}
              aria-describedby="image-description-hint"
              aria-keyshortcuts="Meta+Enter Control+Enter"
              phx-blur="save_image_description"
              phx-hook=".SubmitShortcut"
            />
          </.form>
          <.edit_foot id="image-description" saved={@description_saved} />
        </div>
        <div class="edit">
          <.form for={@note_form} id="note-form" class="note" phx-submit="save_note">
            <.input
              type="textarea"
              field={@note_form[:note]}
              id="link-note"
              class="note-input"
              rows="1"
              maxlength="4000"
              placeholder={gettext("Add a note")}
              aria-label={gettext("Note")}
              aria-describedby="note-hint"
              aria-keyshortcuts="Meta+Enter Control+Enter"
              phx-blur="save_note"
              phx-hook=".SubmitShortcut"
            />
          </.form>
          <.edit_foot id="note" saved={@note_saved} />
        </div>
      </div>

      <div class="acts">
        <a
          id="link-open"
          href={Embed.original_url(@link)}
          target="_blank"
          rel="noopener noreferrer"
          class="round"
          title={gettext("Open original")}
          aria-label={gettext("Open original")}
        >
          <.icon name="lucide-external-link" class="size-4" />
        </a>
        <.link
          :if={@kind in [:text, :pending]}
          id="link-web"
          patch={@web_path}
          class={["round", @web_open && "is-active"]}
          title={web_label(@web_open)}
          aria-label={web_label(@web_open)}
          aria-expanded={to_string(@web_open)}
        >
          <.icon name="lucide-globe" class="size-4" />
        </.link>
        <label
          :if={not @snapshots}
          id="link-screenshot"
          for={@upload.ref}
          class="round"
          title={gettext("Add a screenshot")}
          aria-label={gettext("Add a screenshot")}
        >
          <.icon name="lucide-camera" class="size-4" />
        </label>
        <.image_menu :if={@snapshots} upload={@upload} busy={@snapshot_busy} />
        <.collection_picker
          link={@link}
          collections={@collections}
          filter={@collection_filter}
        />
        <button
          :if={is_nil(@link.triaged_at) and length(@link.suggestions) > 1}
          id="link-accept-all"
          type="button"
          class="round"
          phx-click="accept_all"
          phx-value-id={@link.id}
          title={gettext("Accept all and finish")}
          aria-label={gettext("Accept all and finish")}
        >
          <.icon name="lucide-check-check" class="size-4" />
        </button>
        <button
          :if={is_nil(@link.triaged_at)}
          id="link-done"
          type="button"
          class="round"
          phx-click="finish"
          phx-value-id={@link.id}
          title={gettext("Done")}
          aria-label={gettext("Done")}
        >
          <.icon name="lucide-check" class="size-4" />
        </button>
        <button
          id="link-delete"
          type="button"
          class="round round-danger"
          phx-click="delete"
          data-confirm={gettext("Delete this link?")}
          title={gettext("Delete")}
          aria-label={gettext("Delete")}
        >
          <.icon name="lucide-trash-2" class="size-4" />
        </button>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitShortcut">
      // ⌘↩ (Ctrl+↩ off Apple devices) submits the field's form (the note or
      // the image description) and keeps the caret in it; Enter alone still
      // breaks the line, and leaving the field saves too.
      export default {
        mounted() {
          this.onKeydown = event => {
            if (event.key !== 'Enter' || event.isComposing || event.shiftKey || event.altKey) return
            const mac = document.documentElement.dataset.platform === 'mac'
            if (!(mac ? event.metaKey : event.ctrlKey)) return
            event.preventDefault()
            this.el.form?.requestSubmit()
          }
          this.el.addEventListener('keydown', this.onKeydown)
        },
        destroyed() {
          this.el.removeEventListener('keydown', this.onKeydown)
        }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ScreenshotPaste">
      // Pasting an image while a link is open, outside a field, uploads it as
      // that link's screenshot. It adds another one even when the link already
      // has images, on purpose. Anything else is left to the link-paste hook.
      export default {
        mounted() {
          this.onPaste = event => {
            const target = event.target
            if (target instanceof Element &&
                (target.closest('input, textarea, [contenteditable]') || target.isContentEditable)) return
            const files = Array.from(event.clipboardData?.files || [])
            const image = files.find(file => file.type.startsWith('image/'))
            if (!image) return
            event.preventDefault()
            this.upload('screenshot', [image])
          }
          window.addEventListener('paste', this.onPaste)
        },
        destroyed() {
          window.removeEventListener('paste', this.onPaste)
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true, doc: "prefixes the hint's and status's ids"
  attr :saved, :boolean, required: true

  # Under an editable field, in the gap below it: the shortcut hint while it
  # is focused and a brief "Saved".
  defp edit_foot(assigns) do
    ~H"""
    <div class="note-foot">
      <span id={"#{@id}-hint"} class="note-hint">
        <kbd><.mod_key plus />↩</kbd> {gettext("to save")}
      </span>
      <span id={"#{@id}-status"} class="note-status" role="status" aria-live="polite">
        <span :if={@saved} class="note-saved" phx-remove={JS.transition("is-leaving", time: 300)}>
          <.icon name="lucide-check" class="size-3.5" />{gettext("Saved")}
        </span>
      </span>
    </div>
    """
  end

  attr :path, :string, required: true
  attr :open, :boolean, required: true
  slot :inner_block, required: true

  defp web_toggle(assigns) do
    ~H"""
    <.link
      id="link-web-toggle"
      patch={@path}
      class={["web-toggle", @open && "is-open"]}
      aria-label={web_label(@open)}
      aria-expanded={to_string(@open)}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp web_label(true = _open), do: gettext("Close page")
  defp web_label(false), do: gettext("Show page")

  @doc """
  Renders the web view column's body: the page or its official embed in a
  sandboxed frame, a quiet placeholder while its embeddability is checked,
  or the reader view when it can't be framed or `reader` asks for it.

  The reader view shows the article captured as `content`, HTML sanitized at
  capture by `Acervo.Library.Sanitizer`, or else the captured text.
  """
  attr :link, :map, required: true
  attr :check, :any, default: nil, doc: "`{:checking | :failed, link_id}` while or after a background check"
  attr :content, :string, default: nil, doc: "the article's sanitized HTML"
  attr :reader, :boolean, default: false, doc: "show a framed page's article instead"

  def web_view(assigns) do
    frame = Embed.frame(assigns.link)
    view = if assigns.reader and is_binary(assigns.content) and match?({:page, _}, frame), do: :reader, else: frame

    assigns = assign(assigns, :view, web_state(view, assigns.check, assigns.link.id))

    ~H"""
    <%= case @view do %>
      <% {:frame, kind, url} -> %>
        <div id="web-view" class={["web-view", "web-view-#{kind}"]}>
          <iframe
            id="web-frame"
            class="web-frame"
            src={url}
            title={display_title(@link)}
            sandbox="allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox allow-forms allow-presentation"
            referrerpolicy={referrer_policy(kind)}
            loading="lazy"
            allow="fullscreen; picture-in-picture; encrypted-media"
            data-kind={kind}
            phx-hook=".EmbedHeight"
            phx-mounted={JS.ignore_attributes(["style", "data-sized"])}
          ></iframe>
        </div>
      <% :loading -> %>
        <div
          id="web-loading"
          class="web-view web-loading"
          role="status"
          aria-label={gettext("Loading")}
        >
          <div class="skeleton" aria-hidden="true"></div>
        </div>
      <% :reader when is_binary(@content) -> %>
        <div id="web-reader" class="web-reader">
          <p :if={@link.content_source == :markdown} class="reader-source">Markdown</p>
          <article id="web-reader-content" class="reader">{Phoenix.HTML.raw(@content)}</article>
        </div>
      <% :reader -> %>
        <div id="web-reader" class="web-reader">
          <div class="web-reader-head">
            <p class="web-hint">
              <.icon name="lucide-info" class="size-3.5" />{gettext("This page can't be shown here.")}
            </p>
            <.pill_button
              id="web-reader-open"
              href={Embed.original_url(@link)}
              target="_blank"
              rel="noopener noreferrer"
              icon="lucide-arrow-up-right"
            >
              {gettext("Open original")}
            </.pill_button>
          </div>
          <div :if={@link.text_excerpt} id="web-reader-text" class="web-reader-text">
            <p :for={paragraph <- paragraphs(@link.text_excerpt)}>{paragraph}</p>
          </div>
        </div>
    <% end %>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".EmbedHeight">
      // X and Instagram embeds report their content's height to the parent;
      // the frame takes it so a short post doesn't sit on a tall blank page.
      // Only posts, and only messages from this frame's own window, count.
      const height = data => {
        if (typeof data === 'string') {
          try { data = JSON.parse(data) } catch { return null }
        }
        const x = data?.['twttr.embed']
        if (x?.method === 'twttr.private.resize') return x.params?.[0]?.height
        if (data?.type === 'MEASURE') return data.details?.height
        return null
      }
      export default {
        mounted() {
          this.onMessage = event => {
            if (this.el.dataset.kind !== 'post' || event.source !== this.el.contentWindow) return
            const value = Number(height(event.data))
            if (!Number.isFinite(value) || value <= 0) return
            this.el.style.height = `${Math.ceil(value)}px`
            this.el.dataset.sized = ''
          }
          window.addEventListener('message', this.onMessage)
        },
        updated() {
          if (this.el.dataset.kind === 'post') return
          this.el.style.removeProperty('height')
          delete this.el.dataset.sized
        },
        destroyed() {
          window.removeEventListener('message', this.onMessage)
        }
      }
    </script>
    """
  end

  # Frames send no referrer, except YouTube's player, which refuses to play
  # without one (error 153); it gets the app's origin only.
  defp referrer_policy(:video), do: "strict-origin"
  defp referrer_policy(_kind), do: "no-referrer"

  defp web_state(:reader, _check, _id), do: :reader
  defp web_state({:embed, kind, url}, _check, _id), do: {:frame, kind, url}
  defp web_state({:page, url}, _check, _id), do: {:frame, :page, url}
  defp web_state(:unknown, {:failed, id}, id), do: :reader
  defp web_state(:unknown, _check, _id), do: :loading
  defp web_state(:blocked, _check, _id), do: :reader

  defp upload_error(:not_accepted), do: gettext("That file isn't an image.")
  defp upload_error(:too_large), do: gettext("That image is too large.")
  defp upload_error(:too_many_files), do: gettext("Add one image at a time.")
  defp upload_error(_error), do: gettext("That image couldn't be added.")

  attr :link, :map, required: true
  attr :collections, :list, required: true
  attr :filter, Form, required: true

  # The "add to collection" popover: a filter, the matching collections (the
  # link's own ones checked, a click toggles) and a row creating the query.
  defp collection_picker(assigns) do
    choices = collection_choices(assigns.collections, assigns.filter[:query].value)

    assigns =
      assigns
      |> assign(choices)
      |> assign(
        member_ids: MapSet.new(assigns.link.collections, & &1.id),
        errors: Enum.map(assigns.filter.errors, fn {_field, {message, _opts}} -> message end)
      )

    ~H"""
    <.popover
      id="link-collections"
      trigger_id="link-add-collection"
      label={gettext("Add to collection")}
      placement="bottom-start"
      trigger_class="round"
      panel_class="pick"
    >
      <:trigger><.icon name="lucide-folder-plus" class="size-4" /></:trigger>
      <.form
        for={@filter}
        id="collection-filter-form"
        phx-change="filter_collections"
        phx-submit={JS.push("pick_collection") |> close_picker()}
      >
        <.input
          field={@filter[:query]}
          id="collection-filter"
          class="pick-filter"
          placeholder={gettext("Find or create")}
          aria-label={gettext("Find or create")}
          autocomplete="off"
          maxlength="80"
          phx-debounce="150"
          data-autofocus
        />
      </.form>
      <div id="collection-options" class="pick-list">
        <button
          :for={collection <- @options}
          id={"collection-option-#{collection.id}"}
          type="button"
          class="pick-row"
          aria-pressed={to_string(MapSet.member?(@member_ids, collection.id))}
          phx-click={
            if MapSet.member?(@member_ids, collection.id),
              do: JS.push("remove_from_collection", value: %{id: collection.id}),
              else: JS.push("add_to_collection", value: %{id: collection.id}) |> close_picker()
          }
        >
          <.icon name="lucide-folder" class="size-[15px]" />
          <span class="pick-name">{collection.name}</span>
          <.icon
            :if={MapSet.member?(@member_ids, collection.id)}
            name="lucide-check"
            class="size-[15px]"
          />
        </button>
        <button
          :if={@create?}
          id="collection-create"
          type="button"
          class="pick-row pick-create"
          title={gettext("New collection")}
          phx-click={JS.push("create_collection_for_link", value: %{name: @query}) |> close_picker()}
        >
          <.icon name="lucide-plus" class="size-[15px]" />
          <span class="pick-name">“{@query}”</span>
        </button>
        <p :if={@options == [] and not @create?} class="pick-empty">
          {gettext("No collections yet.")}
        </p>
        <p :for={message <- @errors} id="collection-error" class="pick-error" role="alert">
          {message}
        </p>
      </div>
    </.popover>
    """
  end

  defp close_picker(js), do: JS.remove_attribute(js, "open", to: "#link-collections")

  attr :upload, :map, required: true
  attr :busy, :boolean, required: true

  # The camera's menu: a new image from the screenshot service, which shows
  # progress while it runs, or one the user uploads.
  defp image_menu(assigns) do
    ~H"""
    <.popover
      id="link-image-menu"
      trigger_id="link-image"
      label={gettext("Image")}
      menu
      placement="bottom-start"
      trigger_class="round"
      panel_class="dropdown-menu"
    >
      <:trigger><.icon name="lucide-camera" class="size-4" /></:trigger>
      <button
        id="link-snapshot"
        type="button"
        role="menuitem"
        tabindex="-1"
        class="dropdown-item"
        disabled={@busy}
        aria-busy={to_string(@busy)}
        phx-click={JS.push("generate_snapshot") |> close_image_menu()}
      >
        <.icon :if={not @busy} name="lucide-refresh-cw" class="size-4" />
        <.icon :if={@busy} name="lucide-loader-circle" class="size-4 motion-safe:animate-spin" />
        <span class="dropdown-item-label">
          {if @busy, do: gettext("Generating the image…"), else: gettext("Generate a new image")}
        </span>
      </button>
      <label
        id="link-screenshot"
        for={@upload.ref}
        role="menuitem"
        tabindex="-1"
        class="dropdown-item"
        phx-click={close_image_menu()}
      >
        <.icon name="lucide-image-up" class="size-4" />
        <span class="dropdown-item-label">{gettext("Upload an image")}</span>
      </label>
    </.popover>
    """
  end

  defp close_image_menu(js \\ %JS{}), do: JS.remove_attribute(js, "open", to: "#link-image-menu")

  attr :image, :map, required: true
  attr :alt, :string, default: nil

  defp glow(assigns) do
    ~H"""
    <div class="glow">
      <div class="bg" style={"background-image:url(#{image_src(@image)})"} aria-hidden="true"></div>
      <img
        src={image_src(@image)}
        width={@image.width}
        height={@image.height}
        alt={@alt || ""}
      />
    </div>
    """
  end

  attr :image, :map, required: true

  defp video_media(assigns) do
    ~H"""
    <div class="media">
      <img src={image_src(@image)} alt="" />
      <div class="play" aria-hidden="true"><i><.brand name={:youtube} /></i></div>
    </div>
    """
  end

  @doc "Renders the source mark in the card's top right corner."
  attr :source, :atom, required: true

  def source_icon(assigns) do
    ~H"""
    <span class={["src", "src-#{@source}"]} aria-hidden="true"><.brand name={@source} /></span>
    """
  end

  # Brand marks copied from the prototype's <symbol>s.
  attr :name, :atom, required: true

  defp brand(%{name: :x} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24">
      <path
        fill="currentColor"
        d="M17.8 3h3.1l-6.8 7.7L22 21h-6.2l-4.9-6.3L5.3 21H2.2l7.3-8.3L2 3h6.4l4.4 5.8L17.8 3Zm-1.1 16.2h1.7L7.4 4.7H5.6l11.1 14.5Z"
      />
    </svg>
    """
  end

  defp brand(%{name: :youtube} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24">
      <path
        fill="#e2342b"
        d="M23 7.2a3 3 0 0 0-2.1-2.1C19 4.6 12 4.6 12 4.6s-7 0-8.9.5A3 3 0 0 0 1 7.2 31 31 0 0 0 .5 12c0 1.6.2 3.2.5 4.8a3 3 0 0 0 2.1 2.1c1.9.5 8.9.5 8.9.5s7 0 8.9-.5a3 3 0 0 0 2.1-2.1c.3-1.6.5-3.2.5-4.8s-.2-3.2-.5-4.8Z"
      />
      <path fill="#fff" d="m9.8 15.1 5.8-3.1-5.8-3.1v6.2Z" />
    </svg>
    """
  end

  defp brand(%{name: :instagram} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24">
      <rect x="3" y="3" width="18" height="18" rx="5" fill="none" stroke="#c13584" stroke-width="2.2" />
      <circle cx="12" cy="12" r="4" fill="none" stroke="#c13584" stroke-width="2.2" />
      <circle cx="17.3" cy="6.7" r="1.3" fill="#c13584" />
    </svg>
    """
  end

  defp brand(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24">
      <g fill="none" stroke="currentColor" stroke-width="2">
        <circle cx="12" cy="12" r="9" />
        <path d="M3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3Z" />
      </g>
    </svg>
    """
  end

  defdelegate display_title(link), to: LinkPresenter
  defdelegate site_title(link), to: LinkPresenter
  defdelegate host(link), to: LinkPresenter
  defdelegate link_date(link), to: LinkPresenter
  defdelegate format_date(date), to: Format, as: :date
end
