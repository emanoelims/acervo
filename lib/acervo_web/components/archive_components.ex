defmodule AcervoWeb.ArchiveComponents do
  @moduledoc """
  The archive's chrome (approved prototype, option A): the floating dock and
  its settings, the add and search pills, and a collection's menu. Built from
  `AcervoWeb.UIComponents`.
  """
  # Imported by every template through `AcervoWeb.html_helpers/0`, so this
  # module cannot `use AcervoWeb, :html` (it would import itself).
  use Phoenix.Component
  use Gettext, backend: AcervoWeb.Gettext
  use AcervoWeb, :verified_routes

  import AcervoWeb.CoreComponents
  import AcervoWeb.UIComponents

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @doc """
  Renders the floating glass dock with home, search, inbox, settings and add.
  The settings hold the appearance, the automatic notes setting
  (`auto_notes`), the guide, the import and log out.
  """
  attr :active, :atom, values: [:home, :search, :inbox], required: true
  attr :inbox_count, :integer, default: 0
  attr :adding, :boolean, default: false
  attr :searching, :boolean, default: false
  attr :locale, :string, required: true
  attr :return_to, :string, required: true
  attr :auto_notes, :atom, values: [:never, :long, :always], default: :never

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
        <.auto_notes_setting value={@auto_notes} />
        <div class="dock-panel-divider"></div>
        <.link id="dock-guide" patch={~p"/guide"} class="dock-panel-row">
          <.icon name="lucide-keyboard" class="size-4" /><span>{gettext("Shortcuts and features")}</span>
        </.link>
        <.link id="dock-import" patch={~p"/import"} class="dock-panel-row">
          <.icon name="lucide-bookmark-plus" class="size-4" /><span>{gettext("Import bookmarks")}</span>
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
    <.float_pill id="add-pill" icon="lucide-link" phx-window-keydown="close_add" phx-key="Escape">
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
      <:kbd>↵</:kbd>
    </.float_pill>
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
    <.float_pill
      id="search-pill"
      icon="lucide-search"
      loading={@loading}
      class="search-float"
      role="search"
      phx-window-keydown="close_search"
      phx-key="Escape"
    >
      <.chip :if={@scope} id="search-scope" size="sm" class="search-scope" title={@scope.name}>
        <.icon name="lucide-folder" class="size-3.5 flex-none" />
        <span class="search-scope-name">{@scope.name}</span>
        <.chip_remove
          id="search-scope-clear"
          label={gettext("Search everything")}
          phx-click="clear_search_scope"
        />
      </.chip>
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
      <:kbd><.mod_key />K</:kbd>
    </.float_pill>
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
      <.dropdown_item
        id="rename-collection"
        icon="lucide-pen-line"
        label={gettext("Rename")}
        phx-click={JS.push("edit_collection", value: %{field: "name"}) |> close_menu()}
      />
      <.dropdown_item
        id="describe-collection"
        icon="lucide-align-left"
        label={gettext("Description")}
        phx-click={JS.push("edit_collection", value: %{field: "description"}) |> close_menu()}
      />
      <div class="dropdown-divider" role="separator"></div>
      <.dropdown_item
        id="delete-collection"
        icon="lucide-trash-2"
        label={gettext("Delete")}
        danger
        phx-click="delete_collection"
        data-confirm={gettext("Delete this collection? Its links stay in your archive.")}
      />
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
  Renders the automatic notes setting: when AI notes are written without
  asking. Clicking pushes `set_auto_notes` with the value.

  ## Examples

      <.auto_notes_setting value={:never} />
  """
  attr :value, :atom, values: [:never, :long, :always], required: true

  def auto_notes_setting(assigns) do
    assigns =
      assign(assigns, :options, [
        {:never, gettext("Never"), gettext("Only when you ask")},
        {:long, gettext("Long"), gettext("For articles over about 1,500 words")},
        {:always, gettext("Always"), gettext("For every link")}
      ])

    ~H"""
    <div
      id="auto-notes"
      class="appearance auto-notes"
      role="group"
      aria-label={gettext("Automatic notes")}
    >
      <div class="appearance-row">
        <span class="auto-notes-glyph" title={gettext("Automatic notes")}>
          <.icon name="lucide-sparkles" class="size-4" />
        </span>
        <button
          :for={{value, label, hint} <- @options}
          id={"auto-notes-#{value}"}
          type="button"
          class={["lang-chip", @value == value && "is-active"]}
          title={hint}
          aria-pressed={to_string(@value == value)}
          phx-click="set_auto_notes"
          phx-value-value={value}
        >
          {label}
        </button>
      </div>
    </div>
    """
  end

  defp locale_code("pt_BR"), do: "PT"
  defp locale_code("en"), do: "EN"

  defp locale_name("pt_BR"), do: "Português"
  defp locale_name("en"), do: "English"
end
