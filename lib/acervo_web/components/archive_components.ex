defmodule AcervoWeb.ArchiveComponents do
  @moduledoc "Columns, navigation and the floating dock (approved prototype, option A)."
  # Imported by every template through `AcervoWeb.html_helpers/0`, so this
  # module cannot `use AcervoWeb, :html` (it would import itself).
  use Phoenix.Component
  use Gettext, backend: AcervoWeb.Gettext
  use AcervoWeb, :verified_routes

  import AcervoWeb.CoreComponents

  alias Phoenix.LiveView.JS

  @doc """
  Renders one Finder-style column. Titled columns get a heading and the ↑ pill
  that appears once the column scrolls, returning it to the top.
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :class, :string, default: nil
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
      <div class="column-scroll" id={"#{@id}-scroll"} phx-hook=".ColumnScroll">
        <header :if={@title} class="column-head">
          <h2>
            <span class="column-title">{@title}</span><span class="chev" aria-hidden="true">›</span>
          </h2>
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
  slot :inner_block, required: true

  def empty(assigns) do
    ~H"""
    <p class="empty">{render_slot(@inner_block)}</p>
    """
  end

  @doc "Renders the floating glass dock with home, inbox and settings."
  attr :active, :atom, values: [:home, :inbox], required: true
  attr :inbox_count, :integer, default: 0
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
        <.link id="dock-log-out" href={~p"/users/log-out"} method="delete" class="dock-panel-row">
          <.icon name="lucide-log-out" class="size-4" /><span>{gettext("Log out")}</span>
        </.link>
      </.popover>
    </nav>
    """
  end

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

  defp locale_code("pt_BR"), do: "PT"
  defp locale_code("en"), do: "EN"

  defp locale_name("pt_BR"), do: "Português"
  defp locale_name("en"), do: "English"
end
