defmodule AcervoWeb.UIComponents do
  @moduledoc """
  Acervo's design-system primitives: columns and their headers, navigation
  rows, icon and pill buttons, chips, the floating pill, the drop zone and
  small text pieces. Domain components (`AcervoWeb.ArchiveComponents`,
  `AcervoWeb.LinkComponents`) compose them; `/dev/styleguide` shows them all.

  The generator's foundations (`input/1`, `button/1`, `popover/1`, `icon/1`,
  `flash/1`) stay in `AcervoWeb.CoreComponents`. Styles live in
  `assets/css/archive.css` and `assets/css/links.css`, on the tokens of
  `assets/css/tokens.css`.
  """
  # Imported by every template through `AcervoWeb.html_helpers/0`, so this
  # module cannot `use AcervoWeb, :html` (it would import itself).
  use Phoenix.Component

  import AcervoWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS

  @doc """
  Renders one Finder-style column. Titled columns get a `column_head/1` and
  the ↑ pill that appears once the column scrolls, returning it to the top. A
  changed `key` (the item the column shows) scrolls the column back to the
  top. Columns sit in a `<div class="columns">` row.

  ## Examples

      <.column id="column-all" title={gettext("All")}>
        <:actions><.icon_button variant="head" icon="lucide-x" label="Close" patch={~p"/"} /></:actions>
        <p class="desc">Everything you saved.</p>
      </.column>
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  attr :key, :string, default: nil, doc: "the item the column shows; a new one scrolls it to the top"
  slot :heading, doc: "replaces the title in the heading, as an inline rename form does"
  slot :actions, doc: "buttons at the heading's end"
  slot :inner_block, required: true

  def column(assigns) do
    ~H"""
    <section id={@id} class={["column", @class]}>
      <button
        :if={@title}
        id={"#{@id}-up"}
        type="button"
        class="column-up"
        data-column-up
        title={@title}
      >
        <.icon name="lucide-arrow-up" class="size-3.5" /><span>{@title}</span>
      </button>
      <div class="column-scroll" id={"#{@id}-scroll"} data-key={@key} phx-hook=".ColumnScroll">
        <.column_head :if={@title} title={@title}>
          <:heading :if={@heading != []}>{render_slot(@heading)}</:heading>
          <:actions>{render_slot(@actions)}</:actions>
        </.column_head>
        {render_slot(@inner_block)}
      </div>
    </section>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ColumnScroll">
      export default {
        mounted() {
          this.pill = this.el.parentElement.querySelector('[data-column-up]')
          this.onScroll = () => this.pill?.classList.toggle('is-shown', this.el.scrollTop > 150)
          this.onPill = () => this.el.scrollTo({top: 0, behavior: 'smooth'})
          this.el.addEventListener('scroll', this.onScroll, {passive: true})
          this.pill?.addEventListener('click', this.onPill)
          this.el.closest('.columns')?.scrollTo({left: 1e6, behavior: 'smooth'})
          this.key = this.el.dataset.key
        },
        updated() {
          if (this.el.dataset.key === this.key) return
          this.key = this.el.dataset.key
          this.el.scrollTo({top: 0})
        },
        destroyed() {
          this.el.removeEventListener('scroll', this.onScroll)
          this.pill?.removeEventListener('click', this.onPill)
        }
      }
    </script>
    """
  end

  @doc """
  Renders a column's header: its title, one line with an ellipsis, and the
  actions at its end. Every column shares it, so titles line up across the
  row. `column/1` renders it for titled columns; the root column renders it
  itself, as the page's `h1`.

  ## Examples

      <.column_head title="Acervo" level="h1" />
  """
  attr :title, :string, required: true
  attr :level, :string, values: ~w(h1 h2), default: "h2"
  slot :heading, doc: "replaces the title, as an inline rename form does"
  slot :actions

  def column_head(assigns) do
    ~H"""
    <header class="column-head">
      <%= if @heading == [] do %>
        <h1 :if={@level == "h1"}><span class="column-title">{@title}</span></h1>
        <h2 :if={@level == "h2"}><span class="column-title">{@title}</span></h2>
      <% end %>
      {render_slot(@heading)}
      {render_slot(@actions)}
    </header>
    """
  end

  @doc """
  Renders a root navigation row that patches to its section, with an optional
  count and a dot for something waiting. Rows sit in a `<ul class="nav">`.

  ## Examples

      <.nav_item id="nav-inbox" navigate={~p"/inbox"} active count={3} dot>Inbox</.nav_item>
  """
  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  attr :count, :integer, default: nil
  attr :dot, :boolean, default: false
  slot :inner_block, required: true

  def nav_item(assigns) do
    ~H"""
    <li>
      <.link
        id={@id}
        patch={@navigate}
        class={["nav-item", @active && "is-active"]}
        aria-current={@active && "page"}
      >
        {render_slot(@inner_block)}
        <span :if={@dot} class="nav-dot" aria-hidden="true"></span>
        <span :if={@count} class="nav-count">{@count}</span>
      </.link>
    </li>
    """
  end

  @doc """
  Renders an icon-only button. The label is both its tooltip and its
  accessible name. Like `button/1`, it renders a link when given `href`,
  `navigate` or `patch`, and a `<label>` when given `for`, to open a file
  input.

  Variants: `round` (the link column's actions; `size="sm"` in the inbox
  bar), `head` (a column header's actions), `plain` (a quiet circle, as in
  flash notices) and `nav` (the root column's quiet +).

  ## Examples

      <.icon_button icon="lucide-check" label={gettext("Done")} phx-click="finish" />
      <.icon_button icon="lucide-trash-2" label={gettext("Delete")} danger phx-click="delete" />
      <.icon_button variant="head" icon="lucide-x" label={gettext("Close")} patch={~p"/"} />
      <.icon_button icon="lucide-camera" label={gettext("Add a screenshot")} for={@upload.ref} />
  """
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :variant, :string, values: ~w(round head plain nav), default: "round"
  attr :size, :string, values: ~w(md sm), default: "md", doc: "the round variant's size"
  attr :danger, :boolean, default: false, doc: "turns red on hover, for destructive actions"
  attr :active, :boolean, default: false, doc: "rings the button while what it opens is open"
  attr :type, :string, default: "button", doc: "the button's type, when it renders a button"
  attr :class, :any, default: nil

  attr :rest, :global, include: ~w(href navigate patch replace method download target rel for disabled form name value)

  def icon_button(assigns) do
    assigns =
      assign(assigns,
        classes: [
          variant_class(assigns.variant, assigns.size),
          assigns.danger && "round-danger",
          assigns.active && "is-active",
          assigns.class
        ],
        icon_class: icon_size(assigns.variant, assigns.size)
      )

    case element(assigns.rest) do
      :link ->
        ~H"""
        <.link class={@classes} title={@label} aria-label={@label} {@rest}>
          <.icon name={@icon} class={@icon_class} />
        </.link>
        """

      :label ->
        ~H"""
        <label class={@classes} title={@label} aria-label={@label} {@rest}>
          <.icon name={@icon} class={@icon_class} />
        </label>
        """

      :button ->
        ~H"""
        <button type={@type} class={@classes} title={@label} aria-label={@label} {@rest}>
          <.icon name={@icon} class={@icon_class} />
        </button>
        """
    end
  end

  # A destination makes a link, as in `button/1`; `for` a file input's label.
  defp element(rest) do
    cond do
      link?(rest) -> :link
      rest[:for] -> :label
      true -> :button
    end
  end

  defp link?(rest), do: !!(rest[:href] || rest[:navigate] || rest[:patch])

  defp icon_size("round", "sm"), do: "size-[15px]"
  defp icon_size(_variant, _size), do: "size-4"

  defp variant_class("round", "sm"), do: "round round-sm"
  defp variant_class("round", _size), do: "round"
  defp variant_class("head", _size), do: "head-button"
  defp variant_class("plain", _size), do: "icon-button"
  defp variant_class("nav", _size), do: "nav-add"

  @doc """
  Renders a rounded button with text and an optional trailing icon. A link
  with `href`, `navigate` or `patch`, a button otherwise.

  ## Examples

      <.pill_button href={@url} target="_blank" icon="lucide-arrow-up-right">Open original</.pill_button>
  """
  attr :icon, :string, default: nil, doc: "an icon after the text"
  attr :type, :string, default: "button"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(href navigate patch replace method download target rel disabled form name value)
  slot :inner_block, required: true

  def pill_button(assigns) do
    if link?(assigns.rest) do
      ~H"""
      <.link class={["pill-button", @class]} {@rest}>
        {render_slot(@inner_block)}<.icon :if={@icon} name={@icon} class="size-4" />
      </.link>
      """
    else
      ~H"""
      <button type={@type} class={["pill-button", @class]} {@rest}>
        {render_slot(@inner_block)}<.icon :if={@icon} name={@icon} class="size-4" />
      </button>
      """
    end
  end

  @doc """
  Renders a chip: a collection's name on a card-colored pill. `ai` draws the
  dashed outline of a suggestion; `size="sm"` is the inbox bar's size. Put a
  `chip_remove/1` inside for a ✕.

  ## Examples

      <.chip id="chip-design">Design</.chip>
      <.chip size="sm" ai><.icon name="lucide-sparkle" class="chip-glyph size-[11px]" />Type</.chip>
  """
  attr :size, :string, values: ~w(md sm), default: "md"
  attr :ai, :boolean, default: false, doc: "the dashed suggestion style"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def chip(assigns) do
    ~H"""
    <span class={["chip", @size == "sm" && "chip-sm", @ai && "ai", @class]} {@rest}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Renders the ✕ inside a chip. It shows on hover (always on touch screens).

  ## Examples

      <.chip_remove id="chip-remove-1" label={gettext("Remove from collection")} phx-click="remove" />
  """
  attr :label, :string, required: true, doc: "the accessible name"
  attr :title, :string, default: nil, doc: "the tooltip, when shorter than the label"
  attr :rest, :global

  def chip_remove(assigns) do
    ~H"""
    <button type="button" class="chip-x" title={@title || @label} aria-label={@label} {@rest}>
      <.icon name="lucide-x" class="size-3" />
    </button>
    """
  end

  @doc """
  Renders the quiet dashed chip that holds the suggestions' place while
  Claude reads the link, so nothing jumps when they land.

  ## Examples

      <.waiting_chip :if={@waiting?} size="sm" />
  """
  attr :size, :string, values: ~w(md sm), default: "md"

  def waiting_chip(assigns) do
    ~H"""
    <.chip size={@size} ai class="is-waiting" aria-hidden="true">
      <.icon name="lucide-sparkle" class="chip-glyph size-[11px]" /><i class="wait-bar"></i>
    </.chip>
    """
  end

  @doc """
  Renders the floating pill above the dock: an icon, the content (a form),
  and an optional key hint. It leaves with a short fade when removed.

  ## Examples

      <.float_pill id="add-pill" icon="lucide-link" phx-window-keydown="close_add" phx-key="Escape">
        <.form for={@form} phx-submit="add_link">...</.form>
        <:kbd>↵</:kbd>
      </.float_pill>
  """
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :loading, :boolean, default: false, doc: "pulses the icon"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :kbd, doc: "the key hint at the end"

  def float_pill(assigns) do
    ~H"""
    <div
      id={@id}
      class={["float", @class]}
      phx-remove={JS.transition("is-leaving", time: 200)}
      {@rest}
    >
      <.icon name={@icon} class={["float-icon size-[18px]", @loading && "is-loading"]} />
      {render_slot(@inner_block)}
      <kbd :if={@kbd != []} class="float-kbd" aria-hidden="true">{render_slot(@kbd)}</kbd>
    </div>
    """
  end

  @doc """
  Renders a dashed drop zone for a LiveView upload: a file dropped on it, or
  picked by clicking it, goes to `upload`. It shows each entry's progress and
  the upload's errors, translated by `error_message`. Render the upload's
  `live_file_input/1` in the same form.

  ## Examples

      <.drop_zone
        id="import-drop"
        upload={@uploads.bookmarks}
        icon="lucide-file-up"
        hint={gettext("Drop or choose the .html file")}
        error_id="import-upload-error"
        error_message={&upload_error/1}
      />
  """
  attr :id, :string, required: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :icon, :string, required: true
  attr :hint, :string, required: true
  attr :error_message, :any, required: true, doc: "a function from an upload error to its message"
  attr :error_id, :string, default: nil, doc: "the id of the upload's error message"
  attr :class, :any, default: nil
  slot :inner_block, doc: "more messages after the upload's own"

  def drop_zone(assigns) do
    ~H"""
    <label
      id={@id}
      for={@upload.ref}
      class={["shot-drop", @class, @upload.entries != [] && "is-busy"]}
      phx-drop-target={@upload.ref}
    >
      <.icon name={@icon} class="size-[18px]" />
      <span class="shot-hint">{@hint}</span>
      <span :for={entry <- @upload.entries} class="shot-bar" aria-hidden="true">
        <i style={"width: #{entry.progress}%"}></i>
      </span>
      <span
        :for={
          error <-
            upload_errors(@upload) ++ Enum.flat_map(@upload.entries, &upload_errors(@upload, &1))
        }
        id={@error_id}
        class="shot-error"
        role="alert"
      >
        {@error_message.(error)}
      </span>
      {render_slot(@inner_block)}
    </label>
    """
  end

  @doc """
  Renders a quiet empty-state line.

  ## Examples

      <.empty id="links-empty">Nothing saved yet.</.empty>
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def empty(assigns) do
    ~H"""
    <p id={@id} class={["empty", @class]}>{render_slot(@inner_block)}</p>
    """
  end

  @doc """
  Renders the platform's modifier key: ⌘ on Apple devices, Ctrl elsewhere.
  Both are rendered; CSS keeps the one matching `<html data-platform>`, which
  `app.js` sets. With `plus`, Ctrl is followed by "+" (⌘↩ but Ctrl+↩).

  ## Examples

      <kbd><.mod_key />K</kbd>
  """
  attr :plus, :boolean, default: false

  def mod_key(assigns) do
    ~H"""
    <span class="key-mac">⌘</span><span class="key-other">Ctrl{if @plus, do: "+"}</span>
    """
  end
end
