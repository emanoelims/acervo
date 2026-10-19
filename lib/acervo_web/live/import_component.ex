defmodule AcervoWeb.ImportComponent do
  @moduledoc """
  The `/import` column: bookmarks from a browser's HTML export.

  The file is uploaded and parsed (`Acervo.Library.Bookmarks`) in memory,
  then previewed: totals, each folder with its destination (a collection,
  the inbox or skipped) and the estimated AI cost and time. Nothing is saved
  until "Import" starts it in the background
  (`Acervo.Library.BookmarkImports`); the column then follows its progress,
  sent by `AcervoWeb.ArchiveLive` through `send_update/3` with `:import`.
  The latest import, running or not, shows whenever the column opens.
  """
  use AcervoWeb, :live_component

  alias Acervo.Collections.Collection
  alias Acervo.Library.BookmarkImports
  alias Acervo.Library.Bookmarks
  alias AcervoWeb.Format

  @max_bytes 10_000_000
  @choices [:collection, :inbox, :skip]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(parsed: nil, rows: [], choices: %{}, existing: MapSet.new(), rates: nil, error: nil)
     |> allow_upload(:bookmarks,
       accept: ~w(.html .htm),
       max_entries: 1,
       max_file_size: @max_bytes,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def update(%{import: import}, socket), do: {:ok, assign(socket, :import, import)}

  def update(assigns, socket) do
    socket = assign(socket, :current_scope, assigns.current_scope)

    if Map.has_key?(socket.assigns, :import),
      do: {:ok, socket},
      else: {:ok, assign(socket, :import, BookmarkImports.latest(socket.assigns.current_scope))}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    socket =
      case socket.assigns.uploads.bookmarks.entries do
        [_one] -> socket
        entries -> Enum.reduce(Enum.drop(entries, -1), socket, &cancel_upload(&2, :bookmarks, &1.ref))
      end

    {:noreply, assign(socket, :error, nil)}
  end

  def handle_event("choose", %{"folder" => id, "choice" => choice}, %{assigns: %{parsed: %{}}} = socket) do
    with %{} = row <- Enum.find(socket.assigns.rows, &(&1.id == id)),
         choice when choice in @choices <- Enum.find(@choices, &(Atom.to_string(&1) == choice)),
         true <- choice != :collection or row.collectable? do
      {:noreply, socket |> assign(:choices, Map.put(socket.assigns.choices, row.key, choice)) |> assign_totals()}
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("choose", _params, socket), do: {:noreply, socket}

  def handle_event("start", _params, %{assigns: %{parsed: %{} = parsed}} = socket) do
    case BookmarkImports.start(socket.assigns.current_scope, parsed, socket.assigns.choices) do
      {:ok, import} ->
        {:noreply, socket |> reset() |> assign(:import, import)}

      {:error, :running} ->
        {:noreply, socket |> reset() |> assign(:import, BookmarkImports.latest(socket.assigns.current_scope))}

      {:error, :empty} ->
        {:noreply, socket}
    end
  end

  def handle_event("start", _params, socket), do: {:noreply, socket}

  def handle_event("reset", _params, socket), do: {:noreply, reset(socket)}

  # The import is the one this column shows, and only the scope's own.
  def handle_event("stop", _params, %{assigns: %{import: %{status: :running, id: id}}} = socket) do
    case BookmarkImports.cancel(socket.assigns.current_scope, id) do
      {:ok, import} -> {:noreply, assign(socket, :import, import)}
      {:error, :not_found} -> {:noreply, assign(socket, :import, BookmarkImports.latest(socket.assigns.current_scope))}
    end
  end

  def handle_event("stop", _params, socket), do: {:noreply, socket}

  defp handle_progress(:bookmarks, %{done?: true}, socket) do
    case consume_uploaded_entries(socket, :bookmarks, fn %{path: path}, _entry -> {:ok, File.read!(path)} end) do
      [html] -> {:noreply, preview(socket, html)}
      _none -> {:noreply, socket}
    end
  end

  defp handle_progress(:bookmarks, _entry, socket), do: {:noreply, socket}

  defp preview(socket, html) do
    with true <- bookmarks_file?(html) || {:error, :not_bookmarks},
         %{found: found} = parsed when found > 0 <- Bookmarks.parse(html) do
      scope = socket.assigns.current_scope
      urls = Enum.map(parsed.loose, & &1.url) ++ Enum.flat_map(parsed.folders, fn f -> Enum.map(f.links, & &1.url) end)
      rows = rows(parsed)

      socket
      |> assign(parsed: parsed, rows: rows, error: nil)
      |> assign(choices: Map.new(rows, &{&1.key, &1.default}))
      |> assign(existing: BookmarkImports.existing_urls(scope, urls), rates: BookmarkImports.rates(scope))
      |> assign(found: length(urls))
      |> assign_totals()
    else
      {:error, :not_bookmarks} -> assign(socket, :error, :not_bookmarks)
      %{} -> assign(socket, :error, :no_links)
    end
  end

  defp bookmarks_file?(html), do: String.match?(html, ~r/NETSCAPE-Bookmark-file|<dl[\s>]/i)

  defp reset(socket) do
    assign(socket, parsed: nil, rows: [], choices: %{}, existing: MapSet.new(), rates: nil, error: nil)
  end

  # One row per folder, then the loose links. A folder whose name has no
  # letters or numbers can't name a collection.
  defp rows(parsed) do
    folders =
      parsed.folders
      |> Enum.with_index()
      |> Enum.map(fn {folder, index} ->
        collectable? = Collection.slugify(folder.name) != ""

        %{
          id: "f#{index}",
          key: index,
          label: Bookmarks.display_path(folder.path),
          full: Enum.join(folder.path, " / "),
          icon: if(folder.kind == :reading_list, do: "lucide-book-open", else: "lucide-folder"),
          count: length(folder.links),
          collectable?: collectable?,
          default: if(folder.kind == :folder and collectable?, do: :collection, else: :inbox)
        }
      end)

    loose = %{
      id: "loose",
      key: :loose,
      label: gettext("Without a folder"),
      full: gettext("Without a folder"),
      icon: "lucide-link",
      count: length(parsed.loose),
      collectable?: false,
      default: :inbox
    }

    if parsed.loose == [], do: folders, else: folders ++ [loose]
  end

  defp assign_totals(socket) do
    %{parsed: parsed, choices: choices, existing: existing, rates: rates} = socket.assigns
    chosen = BookmarkImports.chosen_urls(parsed, choices)
    new_urls = Enum.reject(chosen, &MapSet.member?(existing, &1))

    assign(socket,
      chosen: length(chosen),
      new: length(new_urls),
      estimate: BookmarkImports.estimate(rates, new_urls)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="import" class="import">
      <%= if @parsed do %>
        <.preview_step
          parsed={@parsed}
          rows={@rows}
          choices={@choices}
          found={@found}
          existing={MapSet.size(@existing)}
          new={@new}
          chosen={@chosen}
          estimate={@estimate}
          target={@myself}
        />
      <% else %>
        <.progress :if={@import} import={@import} target={@myself} />
        <.upload_step
          :if={!running?(@import)}
          upload={@uploads.bookmarks}
          error={@error}
          target={@myself}
        />
      <% end %>
    </div>
    """
  end

  attr :upload, :map, required: true
  attr :error, :atom, required: true
  attr :target, :any, required: true

  defp upload_step(assigns) do
    ~H"""
    <div id="import-upload">
      <p class="desc">
        {gettext("Export your browser's bookmarks as an HTML file and drop it here.")}
      </p>
      <ul class="guide-list import-help">
        <li id="import-help-chromium" class="guide-row">
          <.icon name="lucide-globe" class="guide-glyph size-4" />
          <span>
            <strong>Chrome, Edge, Brave, Arc</strong>
            <span class="import-path">{gettext("Bookmark manager → ⋮ → Export bookmarks")}</span>
          </span>
        </li>
        <li id="import-help-safari" class="guide-row">
          <.icon name="lucide-compass" class="guide-glyph size-4" />
          <span>
            <strong>Safari</strong>
            <span class="import-path">{gettext("File → Export → Bookmarks…")}</span>
          </span>
        </li>
        <li id="import-help-firefox" class="guide-row">
          <.icon name="lucide-flame" class="guide-glyph size-4" />
          <span>
            <strong>Firefox</strong>
            <span class="import-path">
              {gettext("Bookmarks → Manage bookmarks → Import and Backup → Export Bookmarks to HTML…")}
            </span>
          </span>
        </li>
      </ul>
      <.form for={%{}} id="import-form" phx-change="validate" phx-target={@target}>
        <.live_file_input upload={@upload} class="sr-only" tabindex="-1" />
        <.drop_zone
          id="import-drop"
          upload={@upload}
          icon="lucide-file-up"
          hint={gettext("Drop or choose the .html file")}
          error_id="import-upload-error"
          error_message={&upload_error/1}
          class="import-drop"
        >
          <span :if={@error} id="import-error" class="shot-error" role="alert">{upload_error(@error)}</span>
        </.drop_zone>
      </.form>
    </div>
    """
  end

  attr :parsed, :map, required: true
  attr :rows, :list, required: true
  attr :choices, :map, required: true
  attr :found, :integer, required: true
  attr :existing, :integer, required: true
  attr :new, :integer, required: true
  attr :chosen, :integer, required: true
  attr :estimate, :map, required: true
  attr :target, :any, required: true

  defp preview_step(assigns) do
    ~H"""
    <div id="import-preview">
      <dl class="import-stats">
        <div>
          <dt>{gettext("links")}</dt>
          <dd id="import-found">{Format.number(@found)}</dd>
        </div>
        <div>
          <dt>{gettext("already saved")}</dt>
          <dd id="import-existing">{Format.number(@existing)}</dd>
        </div>
        <div>
          <dt>{gettext("new")}</dt>
          <dd id="import-new">{Format.number(@new)}</dd>
        </div>
      </dl>
      <p :if={@parsed.truncated > 0} id="import-truncated" class="import-note">
        <.icon name="lucide-info" class="size-4 flex-none" />
        <span>
          {gettext("Only the first %{max} links are imported; %{count} more were left out.",
            max: Format.number(Bookmarks.max_links()),
            count: Format.number(@parsed.truncated)
          )}
        </span>
      </p>
      <ul id="import-folders" class="import-folders">
        <li :for={row <- @rows} id={"import-folder-#{row.id}"} class="import-folder">
          <.icon name={row.icon} class="import-folder-icon size-4" />
          <span class="import-folder-name" title={row.full}>{row.label}</span>
          <span class="import-folder-count">{Format.number(row.count)}</span>
          <div class="import-choice" role="group" aria-label={row.full}>
            <button
              :for={{choice, icon, label} <- choice_options()}
              id={"import-choice-#{row.id}-#{choice}"}
              type="button"
              class="import-choice-button"
              aria-pressed={to_string(@choices[row.key] == choice)}
              title={label}
              aria-label={label}
              disabled={choice == :collection and not row.collectable?}
              phx-click="choose"
              phx-value-folder={row.id}
              phx-value-choice={choice}
              phx-target={@target}
            >
              <.icon name={icon} class="size-4" />
            </button>
          </div>
        </li>
      </ul>
      <p
        id="import-estimate"
        class="import-estimate"
        title={gettext("Claude describes each new link. Estimated from your recent links.")}
      >
        <.icon name="lucide-sparkle" class="size-4 flex-none" />
        <span>{Format.usd(@estimate.cost_usd)} · {Format.duration(@estimate.seconds)}</span>
      </p>
      <div class="import-actions">
        <.icon_button
          id="import-reset"
          variant="head"
          icon="lucide-rotate-ccw"
          label={gettext("Choose another file")}
          phx-click="reset"
          phx-target={@target}
        />
        <.button
          id="import-start"
          variant="primary"
          phx-click="start"
          phx-target={@target}
          phx-disable-with={gettext("Importing…")}
          disabled={@chosen == 0}
        >
          {gettext("Import")}
        </.button>
      </div>
    </div>
    """
  end

  attr :import, :map, required: true
  attr :target, :any, required: true

  defp progress(assigns) do
    ~H"""
    <section id="import-progress" class={["import-progress", "is-#{@import.status}"]}>
      <p class="import-status">
        <.icon name={status_icon(@import.status)} class="import-status-icon size-4" />
        <span id="import-status">{status_text(@import.status)}</span>
        <button
          :if={@import.status == :running}
          id="import-stop"
          type="button"
          class="import-stop"
          phx-click="stop"
          phx-target={@target}
          title={gettext("Stop")}
        >
          <.icon name="lucide-circle-stop" class="size-4" />{gettext("Stop")}
        </button>
      </p>
      <div
        class="import-bar"
        role="progressbar"
        aria-valuemin="0"
        aria-valuemax={@import.total}
        aria-valuenow={@import.processed}
      >
        <i style={"width: #{percent(@import)}%"}></i>
      </div>
      <p class="import-counts">
        <span id="import-processed">{Format.number(@import.processed)} / {Format.number(@import.total)}</span>
        · <span id="import-created">{new_count(@import.created)}</span>
        <span :if={@import.existing > 0}>
          · {already_count(@import.existing)}
        </span>
      </p>
      <p :if={@import.status == :done and @import.created > 0} class="import-note">
        {gettext("Previews and descriptions keep arriving in the background.")}
      </p>
    </section>
    """
  end

  defp running?(%{status: :running}), do: true
  defp running?(_import), do: false

  defp choice_options do
    [
      {:collection, "lucide-folder", gettext("Collection")},
      {:inbox, "lucide-inbox", gettext("Inbox")},
      {:skip, "lucide-ban", gettext("Skip")}
    ]
  end

  defp percent(%{total: 0}), do: 100
  defp percent(%{processed: processed, total: total}), do: min(100, round(processed * 100 / total))

  defp status_icon(:running), do: "lucide-loader-circle"
  defp status_icon(:done), do: "lucide-circle-check"
  defp status_icon(_stopped), do: "lucide-circle-stop"

  defp status_text(:running), do: gettext("Importing bookmarks")
  defp status_text(:done), do: gettext("Bookmarks imported")
  defp status_text(:cancelled), do: gettext("Import stopped")
  defp status_text(:failed), do: gettext("Import failed")

  defp new_count(count), do: ngettext("%{count} new", "%{count} new", count, count: Format.number(count))

  defp already_count(count),
    do: ngettext("%{count} already saved", "%{count} already saved", count, count: Format.number(count))

  defp upload_error(:not_accepted), do: gettext("Choose the .html file your browser exported.")
  defp upload_error(:too_large), do: gettext("That file is over 10 MB.")
  defp upload_error(:too_many_files), do: gettext("Choose one file.")
  defp upload_error(:not_bookmarks), do: gettext("That isn't a bookmarks file.")
  defp upload_error(:no_links), do: gettext("No links found in that file.")
  defp upload_error(_error), do: gettext("That file couldn't be read.")
end
