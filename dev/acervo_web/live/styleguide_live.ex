defmodule AcervoWeb.StyleguideLive do
  @moduledoc """
  `/dev/styleguide`: the design tokens, every primitive with its variants
  and the domain components inside a real column row, all on in-memory
  example data (`AcervoWeb.Styleguide.Examples`). Development only: routed
  under `dev_routes` and compiled from `dev/`.

  The bar switches theme, accent and font on `<html>` for this page without
  saving the preference. Clicks that would change data show their event in a
  flash instead.
  """
  use AcervoWeb, :live_view

  import AcervoWeb.LinkComponents

  alias Acervo.Library
  alias AcervoWeb.Styleguide.Examples

  @themes ~w(studio light sepia snow dark ink)
  @accents ~w(vermilion cobalt moss graphite)
  @fonts ~w(inter schibsted atkinson newsreader)
  @colors ~w(paper card soft ink body muted faint line separator rule-strong pill accent accent-text danger)

  # Every Lucide icon the app uses, read from its source when this compiles.
  @icons "lib/**/*.{ex,heex}"
         |> Path.wildcard()
         |> Enum.flat_map(&Regex.scan(~r/lucide-[a-z0-9]+(?:-[a-z0-9]+)*/, File.read!(&1)))
         |> List.flatten()
         |> Enum.uniq()
         |> Enum.sort()

  # Events that only keep their form's state; anything else shows a flash.
  @quiet_events ~w(validate_screenshot validate_example validate_form)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Styleguide", links: Examples.links(), collections: Examples.collections())
     |> assign(appearance: %{"theme" => nil, "accent" => nil, "font" => nil})
     |> assign(add_form: nil, search_form: nil, collection_filter: to_form(%{"query" => ""}))
     |> assign(form: example_form())
     |> allow_upload(:screenshot, accept: ~w(.png .jpg .jpeg .webp), max_entries: 1)
     |> allow_upload(:example, accept: ~w(.png .jpg), max_entries: 1)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    key = Enum.find(Map.keys(socket.assigns.links), :image, &(Atom.to_string(&1) == params["link"]))
    link = Map.fetch!(socket.assigns.links, key)

    {:noreply,
     assign(socket,
       open: key,
       link: link,
       note_form: to_form(Library.change_note(link), as: :link),
       description_form: to_form(Library.change_image_description(link), as: :link)
     )}
  end

  @impl true
  def handle_event("appearance", %{"key" => key, "value" => value}, socket) when key in ~w(theme accent font),
    do: {:noreply, update(socket, :appearance, &Map.put(&1, key, value))}

  def handle_event("toggle_add", _params, %{assigns: %{add_form: nil}} = socket),
    do: {:noreply, assign(socket, add_form: to_form(%{"url" => ""}), search_form: nil)}

  def handle_event(event, _params, socket) when event in ~w(toggle_add close_add),
    do: {:noreply, assign(socket, :add_form, nil)}

  def handle_event(event, _params, %{assigns: %{search_form: nil}} = socket) when event in ~w(toggle_search open_search),
    do: {:noreply, assign(socket, search_form: to_form(%{"q" => ""}), add_form: nil)}

  def handle_event(event, _params, socket) when event in ~w(toggle_search close_search),
    do: {:noreply, assign(socket, :search_form, nil)}

  def handle_event("filter_collections", %{"query" => query}, socket),
    do: {:noreply, assign(socket, :collection_filter, to_form(%{"query" => query}))}

  def handle_event("flash", %{"kind" => "error"}, socket),
    do: {:noreply, put_flash(socket, :error, "Something went wrong.")}

  def handle_event("flash", _params, socket), do: {:noreply, put_flash(socket, :info, "Saved.")}

  def handle_event(event, _params, socket) when event in @quiet_events, do: {:noreply, socket}

  def handle_event(event, _params, socket), do: {:noreply, put_flash(socket, :info, "Event: #{event}")}

  defp example_form do
    to_form(%{"name" => "Design", "email" => "", "kind" => "folder", "note" => "", "public" => "true"}, as: :example)
  end

  defp set_appearance(key, value) do
    js = JS.set_attribute({"data-#{key}", value}, to: "html")
    js = if key == "theme", do: JS.set_attribute(js, {"data-theme-mode", value}, to: "html"), else: js
    JS.push(js, "appearance", value: %{key: key, value: value})
  end

  defp link_patch(key), do: ~p"/dev/styleguide?#{[link: key]}"

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        themes: @themes,
        accents: @accents,
        fonts: @fonts,
        colors: @colors,
        icons: @icons
      )

    ~H"""
    <style :type={AcervoWeb.Styleguide.CSS}>
      .sg { position: relative; z-index: 1; height: 100%; overflow-x: hidden; overflow-y: auto; scroll-behavior: smooth; }
      .sg-bar { position: sticky; top: 0; z-index: 30; display: flex; flex-wrap: wrap; align-items: center; gap: 12px 20px; padding: 12px 32px; border-bottom: 1px solid var(--separator); background: color-mix(in oklab, var(--paper) 86%, transparent); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px); }
      .sg-brand svg { width: 22px; height: 22px; }
      .sg-brand { display: flex; align-items: center; gap: 10px; margin-right: auto; color: var(--ink); font-size: 15px; font-weight: 600; }
      .sg-toc { display: flex; gap: 4px; }
      .sg-toc a { padding: 4px 10px; border-radius: 999px; color: var(--muted); font-size: 13px; text-decoration: none; transition: color .2s, background-color .2s; }
      .sg-toc a:hover { background: var(--soft); color: var(--ink); }
      .sg-switch { display: flex; align-items: center; gap: 6px; }
      .sg-switch .font-chip { min-width: 34px; height: 26px; padding: 0 8px; }
      .sg-switch [aria-pressed=true] { box-shadow: 0 0 0 2px var(--ink); }
      .sg-switch .dot[aria-pressed=true] { box-shadow: 0 0 0 2px var(--card), 0 0 0 4px var(--ink); }
      .sg-main { max-width: 1120px; margin: 0 auto; padding: 0 32px 200px; }
      .sg-group { margin: 64px 0 4px; color: var(--faint); font-size: 12px; font-weight: 500; letter-spacing: .08em; text-transform: uppercase; scroll-margin-top: 80px; }
      .sg-section { padding: 28px 0 32px; border-top: 1px solid var(--line); }
      .sg-head { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: 6px 24px; margin-bottom: 20px; }
      .sg-head h2 { margin: 0; color: var(--ink); font-size: 15px; font-weight: 600; line-height: 24px; }
      .sg-usage { color: var(--muted); font: 12px/18px var(--font-mono); overflow-wrap: anywhere; }
      .sg-row { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 20px 28px; }
      .sg-row + .sg-row { margin-top: 24px; }
      .sg-item { display: grid; gap: 8px; justify-items: start; }
      .sg-label { color: var(--faint); font-size: 12px; line-height: 16px; }
      .sg-swatches { display: grid; grid-template-columns: repeat(auto-fill, minmax(112px, 1fr)); gap: 16px; }
      .sg-swatches .sg-item { justify-items: stretch; }
      .sg-swatch { height: 56px; border-radius: 12px; box-shadow: inset 0 0 0 1px var(--line); }
      .sg-type { display: grid; gap: 18px; max-width: 560px; }
      .sg-type .column-head { margin: 0; padding: 0; }
      .sg-box { width: 72px; height: 72px; background: var(--card); box-shadow: var(--card-shadow); }
      .sg-font { color: var(--ink); font-size: 22px; line-height: 30px; }
      .sg-icons { display: grid; grid-template-columns: repeat(auto-fill, minmax(176px, 1fr)); gap: 14px 16px; }
      .sg-icon { display: flex; align-items: center; gap: 10px; color: var(--muted); font-size: 12px; }
      .sg-icon > span:first-child { flex: none; color: var(--ink); }
      .sg-panel { width: 296px; }
      .sg-stage .float, .sg-stage .flash-stack { position: relative; inset: auto; z-index: auto; transform: none; animation: none; }
      .sg-stage .float { width: min(560px, 100%); }
      .sg-columns { height: 340px; overflow: hidden; border-radius: 20px; background: var(--paper); box-shadow: 0 0 0 1px var(--separator); }
      .sg-columns-app { width: calc(100vw - 64px); height: 860px; margin-left: calc(50% - 50vw + 32px); }
      .sg-skeleton { width: 320px; border-radius: 16px; }
      .sg-form { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 0 24px; }
      @media (max-width: 640px) { .sg-bar, .sg-main { padding-inline: 20px; } .sg-toc { display: none; } .sg-columns-app { width: calc(100vw - 40px); margin-left: calc(50% - 50vw + 20px); } }
    </style>
    <Layouts.app flash={@flash}>
      <div id="styleguide" class="sg">
        <header class="sg-bar">
          <div class="sg-brand"><.icon name="acervo-mark" class="size-6" />Styleguide</div>
          <nav class="sg-toc" aria-label="Sections">
            <a href="#sg-tokens">Tokens</a>
            <a href="#sg-primitives">Primitives</a>
            <a href="#sg-domain">Domain</a>
          </nav>
          <div class="sg-switch" role="group" aria-label="Theme">
            <button
              :for={theme <- @themes}
              id={"sg-theme-#{theme}"}
              type="button"
              class={["swatch", "swatch-#{theme}"]}
              title={theme}
              aria-label={theme}
              aria-pressed={to_string(@appearance["theme"] == theme)}
              phx-click={set_appearance("theme", theme)}
            ></button>
          </div>
          <div class="sg-switch" role="group" aria-label="Accent">
            <button
              :for={accent <- @accents}
              id={"sg-accent-#{accent}"}
              type="button"
              class={["dot", "dot-#{accent}"]}
              title={accent}
              aria-label={accent}
              aria-pressed={to_string(@appearance["accent"] == accent)}
              phx-click={set_appearance("accent", accent)}
            ></button>
          </div>
          <div class="sg-switch" role="group" aria-label="Font">
            <button
              :for={font <- @fonts}
              id={"sg-font-#{font}"}
              type="button"
              class={["font-chip", "font-#{font}"]}
              title={font}
              aria-label={font}
              aria-pressed={to_string(@appearance["font"] == font)}
              phx-click={set_appearance("font", font)}
            >
              Aa
            </button>
          </div>
        </header>

        <main class="sg-main">
          <h2 id="sg-tokens" class="sg-group">Tokens</h2>

          <.specimen
            id="sg-colors"
            title="Color"
            usage="var(--ink) · tokens.css, per data-theme and data-accent"
          >
            <div class="sg-swatches">
              <div :for={color <- @colors} class="sg-item">
                <div class="sg-swatch" style={"background: var(--#{color})"}></div>
                <span class="sg-label">--{color}</span>
              </div>
            </div>
          </.specimen>

          <.specimen id="sg-type" title="Type" usage="15/24 body · 12/16 meta · 18/24 titles">
            <div class="sg-type">
              <.example label=".column-head h2 · 18/24 semibold">
                <.column_head title="Good things I find" />
              </.example>
              <.example label=".lead · 15/24">
                <p class="lead">Good things I find on the internet.</p>
              </.example>
              <.example label=".ttl and .sub · 15/24">
                <div>
                  <div class="ttl">The long tail of small software</div>
                  <div class="sub">Why tools made for a handful of people tend to last longer.</div>
                </div>
              </.example>
              <.example label=".date and .meta · 12/16 medium">
                <div class="date">12 Oct 2026</div>
              </.example>
              <.example label=".reader · 16/25.6, headings 20/28">
                <div class="reader">
                  <h2>An article heading</h2>
                  <p>Body text in the reader view, with a <a href="#sg-type">link</a>.</p>
                </div>
              </.example>
            </div>
          </.specimen>

          <.specimen
            id="sg-shape"
            title="Radius and shadow"
            usage="8 · 12 · 16 · 32 · 999 · --card-shadow · --pop-shadow"
          >
            <div class="sg-row">
              <.example :for={radius <- [8, 12, 16, 32, 999]} label={"#{radius}px"}>
                <div class="sg-box" style={"border-radius: #{radius}px"}></div>
              </.example>
              <.example label="--pop-shadow">
                <div class="sg-box" style="border-radius: 16px; box-shadow: var(--pop-shadow)"></div>
              </.example>
            </div>
          </.specimen>

          <.specimen id="sg-fonts" title="Font" usage="data-font on html sets --font-ui">
            <div class="sg-row">
              <.example :for={font <- @fonts} label={font}>
                <div class={["sg-font", "font-#{font}"]}>Aa Good things</div>
              </.example>
            </div>
          </.specimen>

          <.specimen
            id="sg-icons"
            title="Icons"
            usage={~S|<.icon name="lucide-folder" class="size-4" />|}
          >
            <div class="sg-icons">
              <div :for={name <- @icons} class="sg-icon">
                <.icon name={name} class="size-4" /><span>{String.replace_prefix(name, "lucide-", "")}</span>
              </div>
              <div class="sg-icon">
                <.icon name="acervo-mark" class="size-4" /><span>acervo-mark</span>
              </div>
            </div>
          </.specimen>

          <h2 id="sg-primitives" class="sg-group">Primitives</h2>

          <.specimen
            id="sg-buttons"
            title="Buttons"
            usage={~S|<.icon_button icon="lucide-check" label="Done" />|}
          >
            <div class="sg-row">
              <.example label="button">
                <.button id="sg-button" phx-click="flash">Action</.button>
              </.example>
              <.example label="button primary">
                <.button id="sg-button-primary" variant="primary" phx-click="flash">Import</.button>
              </.example>
              <.example label="pill_button">
                <.pill_button id="sg-pill" href="#sg-buttons" icon="lucide-arrow-up-right">
                  Open original
                </.pill_button>
              </.example>
            </div>
            <div class="sg-row">
              <.example label="round">
                <.icon_button id="sg-round" icon="lucide-external-link" label="Open original" />
              </.example>
              <.example label="round active">
                <.icon_button id="sg-round-active" icon="lucide-globe" label="Close page" active />
              </.example>
              <.example label="round danger">
                <.icon_button id="sg-round-danger" icon="lucide-trash-2" label="Delete" danger />
              </.example>
              <.example label="round sm">
                <.icon_button id="sg-round-sm" icon="lucide-check" label="Done" size="sm" />
              </.example>
              <.example label="head">
                <.icon_button id="sg-head" variant="head" icon="lucide-x" label="Close" />
              </.example>
              <.example label="plain">
                <.icon_button id="sg-plain" variant="plain" icon="lucide-x" label="Close" />
              </.example>
              <.example label="nav">
                <.icon_button id="sg-nav-add" variant="nav" icon="lucide-plus" label="New collection" />
              </.example>
            </div>
          </.specimen>

          <.specimen
            id="sg-chips"
            title="Chips"
            usage={~S|<.chip size="sm" ai>…</.chip> · <.chip_remove label="…" />|}
          >
            <div class="sg-row">
              <.example label="chip">
                <.chip id="sg-chip">Design</.chip>
              </.example>
              <.example label="chip with link and remove">
                <.chip id="sg-chip-link">
                  <.link href="#sg-chips" class="chip-link">
                    <.icon name="lucide-folder" class="size-[13px]" />Reading
                  </.link>
                  <.chip_remove id="sg-chip-remove" label="Remove from collection" phx-click="remove" />
                </.chip>
              </.example>
              <.example label="chip sm">
                <.chip id="sg-chip-sm" size="sm">Type</.chip>
              </.example>
              <.example label="ai">
                <.chip id="sg-chip-ai" ai>
                  <.icon name="lucide-sparkle" class="chip-glyph size-[11px]" /><span class="chip-name">Design</span>
                </.chip>
              </.example>
              <.example label="ai sm, new name">
                <.chip id="sg-chip-ai-sm" size="sm" ai>
                  <.icon name="lucide-plus" class="chip-glyph size-3" /><span class="chip-name">Landscapes</span>
                </.chip>
              </.example>
              <.example label="waiting_chip">
                <.waiting_chip />
              </.example>
              <.example label="waiting_chip sm">
                <.waiting_chip size="sm" />
              </.example>
            </div>
          </.specimen>

          <.specimen
            id="sg-nav"
            title="Navigation"
            usage={~S|<.nav_item id="…" navigate={…} count={3} dot>Inbox</.nav_item>|}
          >
            <div class="sg-panel">
              <ul class="nav">
                <.nav_item id="sg-nav-inbox" navigate={link_patch(:image)} count={2} dot>
                  Inbox
                </.nav_item>
                <.nav_item id="sg-nav-all" navigate={link_patch(:image)} count={128} active>
                  All
                </.nav_item>
                <li class="nav-sep" aria-hidden="true"></li>
                <.nav_item
                  :for={collection <- @collections}
                  id={"sg-nav-#{collection.slug}"}
                  navigate={link_patch(:image)}
                  count={collection.link_count}
                >
                  {collection.name}
                </.nav_item>
                <li>
                  <.icon_button
                    id="sg-nav-new"
                    variant="nav"
                    icon="lucide-plus"
                    label="New collection"
                  />
                </li>
              </ul>
            </div>
          </.specimen>

          <.specimen
            id="sg-column"
            title="Column"
            usage={~S|<.column id="…" title="…"><:actions>…</:actions>…</.column>|}
          >
            <div class="sg-columns">
              <div class="columns">
                <.column id="sg-col-a" title="A column">
                  <:actions><.collection_menu /></:actions>
                  <p class="desc">A description under the title, then the column's content.</p>
                  <.empty>Nothing here yet.</.empty>
                </.column>
                <.column
                  id="sg-col-b"
                  title="A long title that ends in an ellipsis before the actions"
                >
                  <:actions>
                    <div class="head-acts">
                      <.icon_button variant="head" icon="lucide-book-open" label="Show reader view" />
                      <.icon_button variant="head" icon="lucide-x" label="Close" />
                    </div>
                  </:actions>
                  <div class="skeleton sg-skeleton" aria-hidden="true"></div>
                </.column>
              </div>
            </div>
          </.specimen>

          <.specimen
            id="sg-popover"
            title="Popover and menu"
            usage={~S|<.popover id="…" label="…" menu>…</.popover>|}
          >
            <div class="sg-row">
              <.example label="popover">
                <.popover
                  id="sg-popover-dialog"
                  label="Details"
                  placement="bottom-start"
                  trigger_class="round"
                >
                  <:trigger><.icon name="lucide-info" class="size-4" /></:trigger>
                  <p class="lead">A non-modal panel, placed by Floating UI.</p>
                </.popover>
              </.example>
              <.example label="popover menu with dropdown_item">
                <.popover
                  id="sg-popover-menu"
                  label="More"
                  menu
                  placement="bottom-start"
                  trigger_class="head-button"
                  panel_class="dropdown-menu"
                >
                  <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
                  <.dropdown_item icon="lucide-keyboard" label="Shortcuts" href="#sg-popover" />
                  <.dropdown_item icon="lucide-pen-line" label="Rename" phx-click="rename" />
                  <div class="dropdown-divider" role="separator"></div>
                  <.dropdown_item icon="lucide-trash-2" label="Delete" danger phx-click="delete" />
                </.popover>
              </.example>
            </div>
          </.specimen>

          <.specimen
            id="sg-inputs"
            title="Inputs"
            usage={~S|<.input field={@form[:name]} label="Name" />|}
          >
            <.form for={@form} id="sg-form" class="sg-form" phx-change="validate_form">
              <.input field={@form[:name]} label="Text" />
              <.input
                id="sg-input-error"
                name="example[email]"
                type="email"
                label="With an error"
                value=""
                errors={["can't be blank"]}
              />
              <.input
                field={@form[:kind]}
                type="select"
                label="Select"
                options={[Folder: "folder", Inbox: "inbox", Skip: "skip"]}
              />
              <.input field={@form[:public]} type="checkbox" label="Checkbox" />
              <.input field={@form[:note]} type="textarea" label="Textarea" placeholder="A note" />
            </.form>
          </.specimen>

          <.specimen
            id="sg-float"
            title="Floating pill"
            usage={~S|<.float_pill id="…" icon="lucide-link">…<:kbd>↵</:kbd></.float_pill>|}
          >
            <div class="sg-stage">
              <.float_pill id="sg-float-pill" icon="lucide-link">
                <div class="float-form">
                  <input class="float-input" placeholder="Paste a link" aria-label="Paste a link" />
                </div>
                <:kbd>↵</:kbd>
              </.float_pill>
            </div>
          </.specimen>

          <.specimen
            id="sg-drop"
            title="Drop zone"
            usage={~S|<.drop_zone id="…" upload={@uploads.file} icon="…" hint="…" />|}
          >
            <.form for={%{}} id="sg-drop-form" phx-change="validate_example">
              <.live_file_input upload={@uploads.example} class="sr-only" tabindex="-1" />
              <.drop_zone
                id="sg-drop-zone"
                upload={@uploads.example}
                icon="lucide-file-up"
                hint="Drop or choose an image"
                error_id="sg-drop-error"
                error_message={&"#{&1}"}
              />
            </.form>
          </.specimen>

          <.specimen id="sg-flash" title="Flash" usage={~S|put_flash(socket, :info, "Saved.")|}>
            <div class="sg-row sg-stage">
              <.flash id="sg-flash-info" kind={:info}>Saved.</.flash>
              <.flash id="sg-flash-error" kind={:error} title="Something went wrong!">
                Attempting to reconnect
              </.flash>
            </div>
            <div class="sg-row">
              <.button id="sg-flash-show-info" phx-click="flash" phx-value-kind="info">Info</.button>
              <.button id="sg-flash-show-error" phx-click="flash" phx-value-kind="error">Error</.button>
            </div>
          </.specimen>

          <.specimen
            id="sg-empty"
            title="Empty and loading"
            usage={~S|<.empty>Nothing here yet.</.empty> · class="skeleton"|}
          >
            <div class="sg-row">
              <.example label="empty">
                <.empty>Nothing saved yet.</.empty>
              </.example>
              <.example label="skeleton">
                <div class="skeleton sg-skeleton" aria-hidden="true"></div>
              </.example>
            </div>
          </.specimen>

          <h2 id="sg-domain" class="sg-group">Domain</h2>

          <.specimen
            id="sg-app"
            title="Columns"
            usage={
              ~S|<.card link={…} patch={…} /> · <.inbox_item … /> · <.link_detail … /> · <.web_view … />|
            }
          >
            <div class="sg-columns sg-columns-app">
              <div class="columns">
                <.column id="sg-column-root" class="column-root">
                  <.column_head title="Acervo" level="h1" />
                  <p class="lead">Good things I find on the internet.</p>
                  <ul class="nav">
                    <.nav_item id="sg-root-inbox" navigate={link_patch(:suggested)} count={2} dot>
                      Inbox
                    </.nav_item>
                    <.nav_item id="sg-root-all" navigate={link_patch(:image)} count={5} active>
                      All
                    </.nav_item>
                  </ul>
                </.column>
                <.column id="sg-column-all" title="All">
                  <p class="desc">One card of every kind: capturing, text, image and video.</p>
                  <div class="cards">
                    <.card
                      :for={key <- [:pending, :text, :image, :generic_image, :video]}
                      id={"sg-card-#{key}"}
                      link={@links[key]}
                      patch={link_patch(key)}
                      selected={@open == key}
                    />
                  </div>
                </.column>
                <.column id="sg-column-inbox" title="Inbox">
                  <div class="cards">
                    <.inbox_item
                      :for={key <- [:suggested, :reading]}
                      id={"sg-inbox-#{key}"}
                      link={@links[key]}
                      patch={link_patch(key)}
                      selected={@open == key}
                    />
                  </div>
                </.column>
                <.column
                  id="sg-column-link"
                  class="column-link"
                  title={display_title(@link)}
                  key={to_string(@open)}
                >
                  <.link_detail
                    link={@link}
                    note_form={@note_form}
                    collections={@collections}
                    collection_filter={@collection_filter}
                    upload={@uploads.screenshot}
                    description_form={@description_form}
                    web_path={link_patch(@open)}
                  />
                </.column>
                <.column id="sg-column-web" class="column-web" title={site_title(@links.text)}>
                  <.web_view link={@links.text} />
                </.column>
              </div>
            </div>
          </.specimen>

          <.specimen
            id="sg-dock"
            title="Dock and pills"
            usage={
              ~S|<.dock active={:home} … /> · <.add_pill form={…} /> · <.search_pill form={…} />|
            }
          >
            <p class="lead">
              At the bottom of the page, as in the app. + and search open their pills.
            </p>
          </.specimen>
        </main>
      </div>
      <.add_pill :if={@add_form} form={@add_form} />
      <.search_pill :if={@search_form} form={@search_form} scope={hd(@collections)} />
      <.dock
        active={:home}
        inbox_count={2}
        adding={!!@add_form}
        searching={!!@search_form}
        locale={@locale}
        return_to={~p"/dev/styleguide"}
      />
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :usage, :string, default: nil, doc: "a one-line usage snippet"
  slot :inner_block, required: true

  defp specimen(assigns) do
    ~H"""
    <section id={@id} class="sg-section">
      <div class="sg-head">
        <h2>{@title}</h2>
        <code :if={@usage} class="sg-usage">{@usage}</code>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp example(assigns) do
    ~H"""
    <div class="sg-item">
      {render_slot(@inner_block)}
      <span class="sg-label">{@label}</span>
    </div>
    """
  end
end
