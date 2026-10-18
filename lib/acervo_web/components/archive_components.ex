defmodule AcervoWeb.ArchiveComponents do
  @moduledoc "Columns, navigation and the floating dock (approved prototype, option A)."
  # Imported by every template through `AcervoWeb.html_helpers/0`, so this
  # module cannot `use AcervoWeb, :html` (it would import itself).
  use Phoenix.Component
  use Gettext, backend: AcervoWeb.Gettext
  use AcervoWeb, :verified_routes

  import AcervoWeb.CoreComponents

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @doc """
  Renders one Finder-style column. Titled columns get a heading and the ↑ pill
  that appears once the column scrolls, returning it to the top. A changed
  `key` (the item the column shows) scrolls the column back to the top.
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :class, :string, default: nil
  attr :key, :string, default: nil
  slot :heading, doc: "replaces the title in the heading, as an inline rename form does"
  slot :actions
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
        <header :if={@title} class="column-head">
          <h2 :if={@heading == []}>
            <span class="column-title">{@title}</span>
            <.icon name="lucide-chevron-right" class="chev" />
          </h2>
          {render_slot(@heading)}
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

  @doc "Renders a root navigation row that patches to its section."
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

  @doc "Renders a quiet empty-state line."
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def empty(assigns) do
    ~H"""
    <p id={@id} class={["empty", @class]}>{render_slot(@inner_block)}</p>
    """
  end

  @doc "Renders the floating glass dock with home, search, inbox, settings and add."
  attr :active, :atom, values: [:home, :search, :inbox], required: true
  attr :inbox_count, :integer, default: 0
  attr :adding, :boolean, default: false
  attr :searching, :boolean, default: false
  attr :locale, :string, required: true
  attr :return_to, :string, required: true

  def dock(assigns) do
    ~H"""
    <nav id="dock" class="dock" aria-label={gettext("Navigation")}>
      <.link
        id="dock-home"
        patch={~p"/"}
        class={["dock-item", @active == :home && "is-active"]}
        aria-current={@active == :home && "page"}
        title="Acervo"
      >
        <.icon name="lucide-house" class="size-[19px]" /><span class="dock-label">Acervo</span>
      </.link>
      <button
        id="dock-search"
        type="button"
        class={["dock-item", @active == :search && "is-active", @searching && "is-open"]}
        phx-click="toggle_search"
        title={gettext("Search")}
        aria-label={gettext("Search")}
        aria-controls="search-pill"
        aria-expanded={to_string(@searching)}
      >
        <.icon name="lucide-search" class="size-[19px]" /><span class="dock-label">{gettext("Search")}</span>
      </button>
      <.link
        id="dock-inbox"
        patch={~p"/inbox"}
        class={["dock-item", @active == :inbox && "is-active"]}
        aria-current={@active == :inbox && "page"}
        title={gettext("Inbox")}
      >
        <.icon name="lucide-inbox" class="size-[19px]" /><span class="dock-label">{gettext("Inbox")}</span>
        <span :if={@inbox_count > 0} class="dock-badge" aria-hidden="true"></span>
      </.link>
      <.popover
        id="dock-settings"
        label={gettext("Settings")}
        placement="top"
        offset={14}
        class="dock-popover"
        trigger_class="dock-item"
        panel_class="dock-panel"
      >
        <:trigger><.icon name="lucide-settings-2" class="size-[19px]" /></:trigger>
        <.appearance_panel locale={@locale} return_to={@return_to} />
        <div class="dock-panel-divider"></div>
        <.link id="dock-guide" patch={~p"/guide"} class="dock-panel-row">
          <.icon name="lucide-keyboard" class="size-4" /><span>{gettext("Shortcuts and features")}</span>
        </.link>
        <.link id="dock-log-out" href={~p"/users/log-out"} method="delete" class="dock-panel-row">
          <.icon name="lucide-log-out" class="size-4" /><span>{gettext("Log out")}</span>
        </.link>
      </.popover>
      <button
        id="dock-add"
        type="button"
        class={["dock-item", @adding && "is-open"]}
        phx-click="toggle_add"
        title={gettext("Add")}
        aria-label={gettext("Add")}
        aria-controls="add-pill"
        aria-expanded={to_string(@adding)}
      >
        <.icon name="lucide-plus" class="size-[19px]" />
      </button>
    </nav>
    """
  end

  @doc """
  Renders the floating pill above the dock where a link is pasted and saved
  with Enter. Escape closes it.
  """
  attr :form, Form, required: true

  def add_pill(assigns) do
    ~H"""
    <div
      id="add-pill"
      class="float"
      phx-window-keydown="close_add"
      phx-key="Escape"
      phx-remove={JS.transition("is-leaving", time: 200)}
    >
      <.icon name="lucide-link" class="float-icon size-[18px]" />
      <.form for={@form} id="add-link-form" class="float-form" phx-submit="add_link">
        <.input
          field={@form[:url]}
          id="add-link-url"
          class="float-input"
          placeholder={gettext("Paste a link")}
          aria-label={gettext("Paste a link")}
          autocomplete="off"
          inputmode="url"
          spellcheck="false"
          autofocus
          phx-mounted={JS.focus()}
        />
      </.form>
      <kbd class="float-kbd" aria-hidden="true">↵</kbd>
    </div>
    """
  end

  @doc """
  Renders the floating search pill, in the add pill's place. Typing searches
  after a short pause and Enter at once; Escape closes it and keeps the
  results. A search scoped to a collection shows it as a chip whose ✕
  searches everything.
  """
  attr :form, Form, required: true
  attr :scope, :any, default: nil, doc: "the collection the search is scoped to, if any"
  attr :loading, :boolean, default: false

  def search_pill(assigns) do
    ~H"""
    <div
      id="search-pill"
      class="float search-float"
      role="search"
      phx-window-keydown="close_search"
      phx-key="Escape"
      phx-remove={JS.transition("is-leaving", time: 200)}
    >
      <.icon name="lucide-search" class={["float-icon size-[18px]", @loading && "is-loading"]} />
      <span :if={@scope} id="search-scope" class="chip chip-sm search-scope" title={@scope.name}>
        <.icon name="lucide-folder" class="size-3.5 flex-none" />
        <span class="search-scope-name">{@scope.name}</span>
        <button
          id="search-scope-clear"
          type="button"
          class="chip-x"
          phx-click="clear_search_scope"
          title={gettext("Search everything")}
          aria-label={gettext("Search everything")}
        >
          <.icon name="lucide-x" class="size-3" />
        </button>
      </span>
      <.form for={@form} id="search-form" class="float-form" phx-change="search" phx-submit="search">
        <.input
          field={@form[:q]}
          id="search-query"
          class="float-input"
          placeholder={gettext("Describe a link")}
          aria-label={gettext("Search")}
          maxlength="200"
          autocomplete="off"
          inputmode="search"
          enterkeyhint="search"
          spellcheck="false"
          phx-debounce="250"
          autofocus
          phx-mounted={JS.focus()}
        />
      </.form>
      <kbd class="float-kbd" aria-hidden="true"><.mod_key />K</kbd>
    </div>
    """
  end

  @doc "Renders a collection column's ··· menu: rename, describe and delete."
  def collection_menu(assigns) do
    ~H"""
    <.popover
      id="collection-menu"
      label={gettext("More")}
      menu
      placement="bottom-end"
      trigger_class="head-button"
      panel_class="dropdown-menu"
    >
      <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
      <button
        id="rename-collection"
        type="button"
        role="menuitem"
        tabindex="-1"
        class="dropdown-item"
        phx-click={JS.push("edit_collection", value: %{field: "name"}) |> close_menu()}
      >
        <.icon name="lucide-pen-line" class="size-4" />
        <span class="dropdown-item-label">{gettext("Rename")}</span>
      </button>
      <button
        id="describe-collection"
        type="button"
        role="menuitem"
        tabindex="-1"
        class="dropdown-item"
        phx-click={JS.push("edit_collection", value: %{field: "description"}) |> close_menu()}
      >
        <.icon name="lucide-align-left" class="size-4" />
        <span class="dropdown-item-label">{gettext("Description")}</span>
      </button>
      <div class="dropdown-divider" role="separator"></div>
      <button
        id="delete-collection"
        type="button"
        role="menuitem"
        tabindex="-1"
        class="dropdown-item dropdown-item-danger"
        phx-click="delete_collection"
        data-confirm={gettext("Delete this collection? Its links stay in your archive.")}
      >
        <.icon name="lucide-trash-2" class="size-4" />
        <span class="dropdown-item-label">{gettext("Delete")}</span>
      </button>
    </.popover>
    """
  end

  defp close_menu(js), do: JS.remove_attribute(js, "open", to: "#collection-menu")

  @doc "Renders the theme, accent, font and language choices."
  attr :locale, :string, required: true
  attr :return_to, :string, required: true

  def appearance_panel(assigns) do
    assigns =
      assign(assigns,
        themes: [
          {"auto", gettext("Auto")},
          {"studio", gettext("Studio")},
          {"light", gettext("Paper")},
          {"sepia", gettext("Sepia")},
          {"snow", gettext("Snow")},
          {"dark", gettext("Night")},
          {"ink", gettext("Ink")}
        ],
        accents: [
          {"vermilion", gettext("Vermilion")},
          {"cobalt", gettext("Cobalt")},
          {"moss", gettext("Moss")},
          {"graphite", gettext("Graphite")}
        ],
        fonts: [
          {"inter", "Inter"},
          {"schibsted", "Schibsted"},
          {"atkinson", "Atkinson"},
          {"newsreader", "Newsreader"}
        ]
      )

    ~H"""
    <div id="appearance-panel" class="appearance" phx-hook=".Appearance">
      <div class="appearance-row" role="group" aria-label={gettext("Theme")}>
        <button
          :for={{t, label} <- @themes}
          id={"theme-option-#{t}"}
          type="button"
          class={["swatch", "swatch-#{t}"]}
          data-appearance="theme"
          data-value={t}
          title={label}
          aria-label={label}
          phx-mounted={JS.ignore_attributes("aria-pressed")}
          phx-click={JS.dispatch("acervo:appearance", detail: %{key: "theme", value: t})}
        ></button>
      </div>
      <div class="appearance-row" role="group" aria-label={gettext("Accent")}>
        <button
          :for={{a, label} <- @accents}
          id={"accent-option-#{a}"}
          type="button"
          class={["dot", "dot-#{a}"]}
          data-appearance="accent"
          data-value={a}
          title={label}
          aria-label={label}
          phx-mounted={JS.ignore_attributes("aria-pressed")}
          phx-click={JS.dispatch("acervo:appearance", detail: %{key: "accent", value: a})}
        ></button>
      </div>
      <div class="appearance-row" role="group" aria-label={gettext("Font")}>
        <button
          :for={{f, label} <- @fonts}
          id={"font-option-#{f}"}
          type="button"
          class={["font-chip", "font-#{f}"]}
          data-appearance="font"
          data-value={f}
          title={label}
          aria-label={label}
          phx-mounted={JS.ignore_attributes("aria-pressed")}
          phx-click={JS.dispatch("acervo:appearance", detail: %{key: "font", value: f})}
        >
          Aa
        </button>
      </div>
      <div class="appearance-row" role="group" aria-label={gettext("Language")}>
        <.link
          :for={l <- AcervoWeb.Locale.locales()}
          id={"locale-option-#{l}"}
          href={~p"/locale/#{l}?#{[return_to: @return_to]}"}
          class={["lang-chip", @locale == l && "is-active"]}
          aria-current={@locale == l && "true"}
          title={locale_name(l)}
        >
          {locale_code(l)}
        </.link>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Appearance">
      export default {
        mounted() {
          this.sync = () => this.syncButtons()
          window.addEventListener('acervo:appearance-changed', this.sync)
          this.sync()
        },
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

  @doc """
  Renders the platform's modifier key: ⌘ on Apple devices, Ctrl elsewhere.
  Both are rendered; CSS keeps the one matching `<html data-platform>`, which
  `app.js` sets. With `plus`, Ctrl is followed by "+" (⌘↩ but Ctrl+↩).
  """
  attr :plus, :boolean, default: false

  def mod_key(assigns) do
    ~H"""
    <span class="key-mac">⌘</span><span class="key-other">Ctrl{if @plus, do: "+"}</span>
    """
  end

  defp locale_code("pt_BR"), do: "PT"
  defp locale_code("en"), do: "EN"

  defp locale_name("pt_BR"), do: "Português"
  defp locale_name("en"), do: "English"
end
