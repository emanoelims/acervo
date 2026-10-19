defmodule AcervoWeb.ArchiveLive do
  @moduledoc """
  The column browser: root navigation, the selected list of links and the
  open link. Subscribes to the user's link broadcasts and keeps the list,
  the open link and the counts current.

  Links are saved from the dock's pill or by pasting anywhere, and organized
  into collections from the link column; collections are created in column 1
  and renamed, described or deleted from their column's menu. `/guide` opens
  a column describing every feature and shortcut, also opened with `?`.

  `…/l/:id/web` opens one more column with the link's page, framed when it
  allows it (see `Acervo.Library.Embed`) and as a reader view of its article
  otherwise. A framed page with an article toggles to the reader view with
  `?view=reader`. Links captured before capture recorded whether their page
  may be framed are checked once, in the background, when this column opens.

  `/search?q=…` lists the links matching the query (`Acervo.Search`), run
  with `start_async` so the current cards stay until the results arrive. `in`
  scopes it to one collection. Results open under `/search/l/:id`, keeping
  `q` and `in`. The dock's search pill drives it; `/` and ⌘K open the pill.

  The home (`/`) shows, next to the root column, the inbox when it has links
  and one narrow column per collection with links, each with its newest
  links as compact cards (`Acervo.Library.home_columns/2`). Broadcasts reload
  only the columns they touch.

  The link column lists related links, loaded with `assign_async`: the ones
  connected by hand, then the nearest by meaning (`Acervo.Search.related_links/3`).
  "See more similar" opens `/search?similar=<id>`, a search variant listing
  every similar link (filter `{:similar, id}`), whose results open under
  `/search/l/:id`, keeping `similar`. The link's AI notes are written on
  request by `Acervo.AI.GenerateNotes`; the button shows progress until the
  link arrives with new notes, or `{:notes_failed, link}`.

  `/import` opens a column that imports bookmarks from a browser's export
  (`AcervoWeb.ImportComponent`), opened from the dock's settings. The
  import's progress arrives here as `{:import_updated, import}` and is sent
  on to the column.
  """
  use AcervoWeb, :live_view

  import AcervoWeb.GuideComponents
  import AcervoWeb.LinkComponents

  alias Acervo.Accounts
  alias Acervo.Collections
  alias Acervo.Collections.Collection
  alias Acervo.Library
  alias Acervo.Library.Embed
  alias Acervo.Library.Screenshots
  alias Acervo.Library.URL
  alias Acervo.Search
  alias AcervoWeb.ImportComponent
  alias Ecto.Query.CastError
  alias Phoenix.LiveView.AsyncResult

  @max_screenshot_bytes 15_000_000
  @note_saved_ms 1500
  @web_actions [:all_link_web, :inbox_link_web, :collection_link_web, :search_link_web]
  @search_actions [:search, :search_link, :search_link_web]
  # The most a similar list shows: Acervo.Search's vector list size.
  @similar_max 50

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Library.subscribe(socket.assigns.current_scope)

    # The search list opens with its pill, ready to refine the query.
    search_form = if socket.assigns.live_action == :search, do: search_form(params["q"])

    {:ok,
     socket
     |> assign(filter: nil, collection: nil, link: nil, screenshot_link_id: nil, home_columns: nil)
     |> assign(snapshots?: Screenshots.enabled?(), snapshot_requests: %{}, notes_requests: %{})
     |> assign(similar_source: nil, related: nil, related_for: nil)
     |> assign(relation_filter: relation_filter(""), relation_options: nil)
     |> assign(ai_notes_form: nil, ai_notes_saved: nil)
     |> assign(search_form: search_form, search_scope: nil, search_loading: false)
     |> assign(search_partial: false, search_count: nil)
     |> assign(note_form: nil, note_saved: nil, description_form: nil, description_saved: nil)
     |> assign(add_form: nil, new_collection_form: nil, editing: nil, collection_form: nil)
     |> assign(web?: false, web_check: nil, reader_view?: false, reader: nil)
     |> assign(:collection_filter, collection_filter(""))
     |> allow_upload(:screenshot,
       accept: ~w(.png .jpg .jpeg .webp .heic),
       max_entries: 1,
       max_file_size: @max_screenshot_bytes,
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> refresh_counts()
     |> stream_configure(:links, dom_id: &"link-#{&1.id}")
     |> stream(:links, [])}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket = assign(socket, :return_to, return_to(uri))

    action = socket.assigns.live_action

    with {:ok, collection} <- fetch_collection(socket, action, params),
         {:ok, source} <- fetch_similar_source(socket, action, params),
         filter = filter(action, collection, source, params),
         reset? = filter != socket.assigns.filter or renamed?(socket.assigns.collection, collection),
         socket =
           socket
           |> stop_editing(filter, collection)
           |> assign(collection: collection, similar_source: source)
           |> apply_filter(filter, reset?)
           |> sync_search(filter, collection),
         {:ok, link} <- fetch_link(socket, params) do
      {:noreply,
       socket
       |> select_link(link, reset?)
       |> assign_home()
       |> assign(:reader_view?, params["view"] == "reader")
       |> assign_web()
       |> assign_page_title()}
    else
      {:error, :not_found, to} ->
        {:noreply, socket |> put_flash(:error, gettext("Not found.")) |> push_patch(to: to)}
    end
  end

  # The home's columns load when it opens and are dropped when it closes;
  # broadcasts keep them current meanwhile (see `refresh_home/2`).
  defp assign_home(%{assigns: %{live_action: :home, home_columns: nil}} = socket),
    do: assign(socket, :home_columns, Library.home_columns(socket.assigns.current_scope))

  defp assign_home(%{assigns: %{live_action: :home}} = socket), do: socket
  defp assign_home(socket), do: assign(socket, :home_columns, nil)

  # A search's `in` names the collection it is scoped to; an unknown one
  # drops the scope.
  defp fetch_collection(socket, action, %{"in" => slug} = params) when action in @search_actions and is_binary(slug) do
    {:ok, Collections.get_collection_by_slug!(socket.assigns.current_scope, slug)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found, search_path(search_query(params), nil)}
  end

  defp fetch_collection(socket, action, %{"slug" => slug}) when action not in @search_actions do
    {:ok, Collections.get_collection_by_slug!(socket.assigns.current_scope, slug)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found, ~p"/"}
  end

  defp fetch_collection(_socket, _action, _params), do: {:ok, nil}

  # A search's `similar` names the link whose similar links it lists.
  defp fetch_similar_source(socket, action, %{"similar" => id}) when action in @search_actions and is_binary(id) do
    case own_link(socket, id) do
      {:ok, link} -> {:ok, link}
      {:error, :not_found} -> {:error, :not_found, ~p"/all"}
    end
  end

  defp fetch_similar_source(_socket, _action, _params), do: {:ok, nil}

  # Leaving a collection, or searching, drops its rename or description form.
  defp stop_editing(socket, {:collection, id}, %{id: id}), do: socket
  defp stop_editing(socket, _filter, _collection), do: assign(socket, editing: nil, collection_form: nil)

  defp fetch_link(socket, %{"id" => id}) do
    {:ok, Library.get_link!(socket.assigns.current_scope, id)}
  rescue
    _ in [Ecto.NoResultsError, CastError] -> {:error, :not_found, list_path(socket.assigns)}
  end

  defp fetch_link(_socket, _params), do: {:ok, nil}

  defp filter(action, _collection, _source, _params) when action in [:all, :all_link, :all_link_web], do: :all

  defp filter(action, _collection, _source, _params) when action in [:inbox, :inbox_link, :inbox_link_web], do: :inbox

  defp filter(action, collection, _source, _params) when action in [:collection, :collection_link, :collection_link_web],
    do: {:collection, collection.id}

  defp filter(action, _collection, %{id: id}, _params) when action in @search_actions, do: {:similar, id}

  defp filter(action, collection, nil, params) when action in @search_actions,
    do: {:search, search_query(params), collection && collection.id}

  defp filter(action, _collection, _source, _params) when action in [:home, :guide, :import], do: nil

  defp search_query(%{"q" => q}) when is_binary(q), do: q |> String.trim() |> String.slice(0, 200)
  defp search_query(_params), do: ""

  # A renamed collection changes the cards' hrefs, so it re-streams too.
  defp renamed?(%{id: id, slug: old}, %{id: id, slug: new}), do: old != new
  defp renamed?(_old, _new), do: false

  # Re-streams only when the list changes, so opening a link keeps the cards.
  defp apply_filter(socket, _filter, false), do: socket

  defp apply_filter(socket, nil, true),
    do: socket |> assign(:filter, nil) |> reset_search() |> stream(:links, [], reset: true)

  defp apply_filter(socket, {:search, q, collection_id} = filter, true) do
    scope = socket.assigns.current_scope
    searching? = match?({:search, _q, _id}, socket.assigns.filter)
    socket = assign(socket, filter: filter, search_partial: false)

    cond do
      # Too short to search: the recent links, newest first.
      short_query?(q) ->
        links = Library.list_links(scope, filter: if(collection_id, do: {:collection, collection_id}, else: :all))
        socket |> assign(search_loading: false, search_count: nil) |> stream(:links, links, reset: true)

      # Refining a search keeps its cards until the new results replace them.
      searching? ->
        start_search(socket, filter)

      true ->
        socket |> assign(:search_count, nil) |> stream(:links, [], reset: true) |> start_search(filter)
    end
  end

  # Every similar link, nearest first; no model call, but run like a search.
  defp apply_filter(socket, {:similar, _id} = filter, true) do
    scope = socket.assigns.current_scope
    source = socket.assigns.similar_source

    socket
    |> assign(filter: filter, search_partial: false, search_count: nil, search_loading: true)
    |> stream(:links, [], reset: true)
    |> start_async(:search, fn ->
      {filter, %{links: Search.similar_links(scope, source, limit: @similar_max), partial: false}}
    end)
  end

  defp apply_filter(socket, filter, true) do
    links = Library.list_links(socket.assigns.current_scope, filter: filter)
    socket |> assign(:filter, filter) |> reset_search() |> stream(:links, links, reset: true)
  end

  # A search still in flight is dropped as stale when it ends, so the state it
  # would have cleared is cleared here.
  defp reset_search(socket), do: assign(socket, search_loading: false, search_partial: false, search_count: nil)

  # A reset stream renders every card with the new selection already; otherwise
  # the previously and newly selected cards are re-rendered in place. (Inserting
  # them after a reset in the same render would move them to the end.)
  defp select_link(socket, link, true = _reset?), do: assign_link(socket, link)

  defp select_link(socket, link, false = _reset?) do
    previous = socket.assigns.link

    socket
    |> assign_link(link)
    |> restream_existing(previous)
    |> restream_existing(link)
  end

  defp assign_link(socket, link) do
    socket
    |> cancel_screenshots_unless_open(link)
    |> assign_link_fields(link)
    |> assign_related(link)
  end

  # Related links load once per open link, without holding up the column;
  # `reload_related/1` refreshes them in place.
  defp assign_related(socket, nil), do: assign(socket, related: nil, related_for: nil)
  defp assign_related(%{assigns: %{related_for: id}} = socket, %{id: id}), do: socket

  defp assign_related(socket, link) do
    socket
    |> assign(relation_filter: relation_filter(""), relation_options: nil)
    |> load_related(link, reset: true)
  end

  defp load_related(socket, link, opts) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:related_for, link.id)
    |> assign_async(:related, fn -> {:ok, %{related: Search.related_links(scope, link)}} end, opts)
  end

  defp reload_related(%{assigns: %{link: %{} = link}} = socket), do: load_related(socket, link, [])
  defp reload_related(socket), do: socket

  # The links the related section shows now.
  defp related_ids(%{assigns: %{related: %AsyncResult{ok?: true, result: %{} = related}}}),
    do: Enum.map(related.manual ++ related.similar, & &1.id)

  defp related_ids(_socket), do: []

  # A pending screenshot belongs to the link it started on, so moving to
  # another link (or closing the column) drops it.
  defp cancel_screenshots_unless_open(%{assigns: %{screenshot_link_id: id}} = socket, %{id: id}), do: socket

  defp cancel_screenshots_unless_open(socket, _link) do
    socket.assigns.uploads.screenshot.entries
    |> Enum.reduce(socket, &cancel_upload(&2, :screenshot, &1.ref))
    |> assign(:screenshot_link_id, nil)
  end

  defp assign_link_fields(socket, link) do
    assign(socket,
      link: link,
      note_form: link && note_form(link),
      note_saved: nil,
      description_form: link && description_form(link),
      description_saved: nil,
      ai_notes_form: link && ai_notes_form(link),
      ai_notes_saved: nil,
      collection_filter: collection_filter("")
    )
  end

  # The web view column. A page whose embeddability is still unknown is
  # checked once per link while the LiveView lives: `web_check` is
  # `{:checking, id}` meanwhile and `{:failed, id}` when it couldn't tell,
  # which shows the reader view.
  defp assign_web(socket) do
    socket = assign(socket, :web?, socket.assigns.live_action in @web_actions)

    case socket.assigns do
      %{web?: true, link: %{} = link} -> socket |> load_reader(link) |> maybe_check_embeddable(link)
      _closed -> assign(socket, :reader, nil)
    end
  end

  # The article's HTML is only read while the column is open, and again only
  # when its extraction changes.
  defp load_reader(socket, link) do
    key = {link.id, link.content_extracted_at}

    case socket.assigns.reader do
      %{key: ^key} -> socket
      _other -> assign(socket, :reader, %{key: key, html: Library.reader_content(socket.assigns.current_scope, link)})
    end
  end

  defp maybe_check_embeddable(socket, link) do
    case {Embed.frame(link), socket.assigns.web_check} do
      {:unknown, {_state, id}} when id == link.id -> socket
      {:unknown, _check} -> if connected?(socket), do: check_embeddable(socket, link), else: socket
      _known -> socket
    end
  end

  defp check_embeddable(socket, link) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:web_check, {:checking, link.id})
    |> start_async(:embeddable, fn -> Library.check_embeddable(scope, link) end)
  end

  # The result names its filter, so one that arrives after the query or scope
  # changed is dropped.
  defp start_search(socket, {:search, q, collection_id} = filter) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:search_loading, true)
    |> start_async(:search, fn -> {filter, Search.search(scope, q, collection_id: collection_id)} end)
  end

  defp short_query?(q), do: String.length(Search.normalize_query(q)) < 2

  # The pill follows the route: on a search it holds the query and its scope;
  # in a collection it offers that collection as the scope.
  defp sync_search(socket, {:search, q, _id}, collection) do
    form = socket.assigns.search_form && search_form(q)
    assign(socket, search_form: form, search_scope: collection)
  end

  defp sync_search(socket, {:collection, _id}, collection), do: assign(socket, :search_scope, collection)
  defp sync_search(socket, _filter, _collection), do: assign(socket, :search_scope, nil)

  defp search_form(q), do: to_form(%{"q" => q || ""})

  defp restream_existing(socket, nil), do: socket
  defp restream_existing(socket, link), do: stream_insert(socket, :links, link, update_only: true)

  defp note_form(link, attrs \\ %{}), do: to_form(Library.change_note(link, attrs), as: :link)

  defp description_form(link), do: to_form(Library.change_image_description(link), as: :link)

  defp ai_notes_form(link), do: to_form(Library.change_ai_notes(link), as: :link)

  defp relation_filter(query), do: to_form(%{"query" => query})

  defp collection_filter(query), do: to_form(%{"query" => query})

  defp picker_error(query),
    do: to_form(%{"query" => query}, errors: [query: {gettext("Couldn't create that collection."), []}])

  @max_url_bytes 2048
  # The paste hook sends at most 20,000 UTF-16 code units: 60,000 bytes of UTF-8.
  @max_text_bytes 60_000
  @link_events ~w(save_note save_image_description delete add_to_collection remove_from_collection
                  create_collection_for_link pick_collection generate_snapshot save_ai_notes generate_notes
                  filter_relations relate_link relate_first unrelate_link)
  @collection_events ~w(edit_collection validate_collection save_collection delete_collection)

  @impl true
  def handle_event(event, _params, %{assigns: %{link: nil}} = socket) when event in @link_events, do: {:noreply, socket}

  def handle_event(event, _params, %{assigns: %{collection: nil}} = socket) when event in @collection_events,
    do: {:noreply, socket}

  # On a search, `collection` is only its scope.
  def handle_event(event, _params, %{assigns: %{filter: {:search, _q, _id}}} = socket) when event in @collection_events,
    do: {:noreply, socket}

  # The screenshot upload starts on its own; a new pick replaces a failed one.
  def handle_event("validate_screenshot", _params, socket) do
    socket =
      case socket.assigns.uploads.screenshot.entries do
        [_one] -> socket
        entries -> Enum.reduce(Enum.drop(entries, -1), socket, &cancel_upload(&2, :screenshot, &1.ref))
      end

    {:noreply, assign(socket, :screenshot_link_id, socket.assigns.link && socket.assigns.link.id)}
  end

  # A new image for the open link, from the screenshot service. The menu
  # item shows progress until the link arrives with a new snapshot, or the
  # job gives up (`{:snapshot_failed, link}`).
  def handle_event("generate_snapshot", _params, socket) do
    link = socket.assigns.link

    case Library.request_snapshot(socket.assigns.current_scope, link) do
      {:ok, _job} ->
        {:noreply, update(socket, :snapshot_requests, &Map.put(&1, link.id, snapshot_ids(link)))}

      {:error, :not_found} ->
        {:noreply, gone(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't generate the image."))}
    end
  end

  # AI notes for the open link, written in the background. The button shows
  # progress until the link arrives with new notes, or the job gives up
  # (`{:notes_failed, link}`).
  def handle_event("generate_notes", _params, socket) do
    link = socket.assigns.link

    case Library.request_notes(socket.assigns.current_scope, link) do
      {:ok, _job} -> {:noreply, update(socket, :notes_requests, &Map.put(&1, link.id, link.ai_notes_at))}
      {:error, :not_found} -> {:noreply, gone(socket)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, gettext("Couldn't write the notes."))}
    end
  end

  def handle_event("save_ai_notes", %{"link" => %{"ai_notes" => text}}, socket), do: save_ai_notes(socket, text)
  def handle_event("save_ai_notes", %{"value" => text}, socket), do: save_ai_notes(socket, text)

  # Relating the open link by hand, from its picker; the related section
  # follows `{:relations_changed, ids}`.
  def handle_event("filter_relations", %{"query" => query}, socket) when is_binary(query) do
    options =
      if String.trim(query) != "",
        do: Search.relation_candidates(socket.assigns.current_scope, socket.assigns.link, query)

    {:noreply, assign(socket, relation_filter: relation_filter(query), relation_options: options)}
  end

  def handle_event("relate_link", %{"id" => id}, socket) when is_binary(id), do: relate(socket, id)

  def handle_event("relate_first", _params, %{assigns: %{relation_options: [first | _]}} = socket),
    do: relate(socket, first.id)

  def handle_event("relate_first", _params, socket), do: {:noreply, socket}

  def handle_event("unrelate_link", %{"id" => id}, socket) when is_binary(id) do
    _ok = Library.unrelate(socket.assigns.current_scope, socket.assigns.link, id)
    {:noreply, socket}
  end

  # The dock settings' "Automatic notes", read by the enrichment worker.
  def handle_event("set_auto_notes", %{"value" => value}, socket) do
    scope = socket.assigns.current_scope

    case Accounts.update_auto_notes(scope, value) do
      {:ok, user} -> {:noreply, assign(socket, :current_scope, %{scope | user: user})}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  # Adding a link: the dock's pill and pasting anywhere share "add_link".
  def handle_event("toggle_add", _params, %{assigns: %{add_form: nil}} = socket),
    do: {:noreply, assign(socket, add_form: to_form(%{"url" => ""}), search_form: nil)}

  def handle_event(event, _params, socket) when event in ~w(toggle_add close_add),
    do: {:noreply, assign(socket, :add_form, nil)}

  # Nothing legitimate is this long; don't echo it back into the input.
  def handle_event("add_link", %{"url" => text}, socket) when is_binary(text) and byte_size(text) > @max_text_bytes,
    do: {:noreply, add_error(socket, "", invalid_link_error())}

  # Every link in the text is saved. One opens, as before; several stay put,
  # the inbox streaming them in, with one summary. Text without an http(s) or
  # www. link is tried whole, so the pill still takes bare hosts.
  def handle_event("add_link", %{"url" => text}, socket) when is_binary(text) do
    case URL.extract_all(text) do
      [] -> add_link(socket, text)
      [url] -> add_link(socket, url)
      urls -> add_links(socket, urls)
    end
  end

  def handle_event("add_link", _params, socket), do: {:noreply, socket}

  # Searching: the dock's search item and ⌘K toggle the pill, `/` opens it.
  # Typing patches the URL, replacing the entry while already searching, so
  # the history keeps where the search started and not every keystroke.
  def handle_event("toggle_search", _params, %{assigns: %{search_form: nil}} = socket),
    do: {:noreply, open_search(socket)}

  def handle_event("toggle_search", _params, socket), do: {:noreply, assign(socket, :search_form, nil)}
  def handle_event("open_search", _params, %{assigns: %{search_form: nil}} = socket), do: {:noreply, open_search(socket)}
  def handle_event("open_search", _params, socket), do: {:noreply, socket}

  # Esc hides the pill and keeps the results.
  def handle_event("close_search", _params, socket), do: {:noreply, assign(socket, :search_form, nil)}

  def handle_event("search", %{"q" => q}, socket) when is_binary(q) do
    q = search_query(%{"q" => q})
    to = search_path(q, socket.assigns.search_scope)

    case {socket.assigns.filter, socket.assigns.live_action} do
      {{:search, ^q, _id}, :search} -> {:noreply, socket}
      {{:search, _q, _id}, _action} -> {:noreply, push_patch(socket, to: to, replace: true)}
      _other -> {:noreply, push_patch(socket, to: to)}
    end
  end

  def handle_event("search", _params, socket), do: {:noreply, socket}

  # ✕ on the scope chip: search everything.
  def handle_event("clear_search_scope", _params, %{assigns: %{filter: {:search, q, _id}}} = socket),
    do: {:noreply, push_patch(socket, to: search_path(q, nil), replace: true)}

  def handle_event("clear_search_scope", _params, socket), do: {:noreply, assign(socket, :search_scope, nil)}

  # The `?` key, outside fields.
  def handle_event("open_guide", _params, socket), do: {:noreply, push_patch(socket, to: ~p"/guide")}

  # Esc, outside fields and menus, while the web view column is open.
  def handle_event("close_web", _params, %{assigns: %{web?: true, link: %{} = link}} = socket),
    do: {:noreply, push_patch(socket, to: link_path(socket.assigns.filter, socket.assigns.collection, link))}

  def handle_event("close_web", _params, socket), do: {:noreply, socket}

  # Organizing the open link.
  def handle_event("filter_collections", %{"query" => query}, socket),
    do: {:noreply, assign(socket, :collection_filter, collection_filter(query))}

  def handle_event("add_to_collection", %{"id" => id}, socket) do
    case own_collection(socket, id) do
      nil -> {:noreply, socket}
      collection -> add_to(socket, collection)
    end
  end

  def handle_event("remove_from_collection", %{"id" => id}, socket) do
    case own_collection(socket, id) do
      %Collection{} = collection ->
        case Collections.remove_link(socket.assigns.current_scope, collection, socket.assigns.link) do
          :ok -> {:noreply, left_collection(socket, collection)}
          {:error, :not_found} -> {:noreply, gone(socket)}
        end

      _unknown ->
        {:noreply, socket}
    end
  end

  def handle_event("create_collection_for_link", %{"name" => name}, socket), do: pick_or_create(socket, name)
  def handle_event("pick_collection", %{"query" => query}, socket), do: pick_or_create(socket, query)

  # Collections: create in column 1; rename, describe and delete in their column.
  def handle_event("new_collection", _params, socket),
    do: {:noreply, assign(socket, :new_collection_form, to_form(Collections.change_collection(%Collection{})))}

  def handle_event("cancel_new_collection", _params, socket), do: {:noreply, assign(socket, :new_collection_form, nil)}

  def handle_event("validate_new_collection", %{"collection" => attrs}, socket) do
    changeset = Collections.change_collection(%Collection{}, attrs)
    {:noreply, assign(socket, :new_collection_form, to_form(changeset, action: :validate))}
  end

  # Enter and blurring the name both create it, so whichever arrives second
  # finds the form gone. A blank name just closes it.
  def handle_event("create_collection", _params, %{assigns: %{new_collection_form: nil}} = socket), do: {:noreply, socket}

  def handle_event("create_collection", %{"value" => name}, socket) do
    if String.trim(name) == "",
      do: {:noreply, assign(socket, :new_collection_form, nil)},
      else: create_collection(socket, %{"name" => name})
  end

  def handle_event("create_collection", %{"collection" => attrs}, socket), do: create_collection(socket, attrs)

  def handle_event("edit_collection", %{"field" => field}, socket) when field in ~w(name description) do
    form = to_form(Collections.change_collection(socket.assigns.collection))
    {:noreply, assign(socket, editing: String.to_existing_atom(field), collection_form: form)}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, editing: nil, collection_form: nil)}

  def handle_event("validate_collection", %{"collection" => attrs}, socket) do
    changeset = Collections.change_collection(socket.assigns.collection, attrs)
    {:noreply, assign(socket, :collection_form, to_form(changeset, action: :validate))}
  end

  # Enter and blurring both save the field being edited; the second finds the form gone.
  def handle_event("save_collection", _params, %{assigns: %{editing: nil}} = socket), do: {:noreply, socket}

  def handle_event("save_collection", %{"value" => value}, socket),
    do: save_collection(socket, %{to_string(socket.assigns.editing) => value})

  def handle_event("save_collection", %{"collection" => attrs}, socket), do: save_collection(socket, attrs)

  def handle_event("delete_collection", _params, socket) do
    case Collections.delete_collection(socket.assigns.current_scope, socket.assigns.collection) do
      {:ok, _collection} -> {:noreply, push_patch(socket, to: ~p"/")}
      {:error, :not_found} -> {:noreply, socket |> put_flash(:error, gettext("Not found.")) |> push_patch(to: ~p"/")}
    end
  end

  def handle_event("save_note", %{"link" => %{"note" => note}}, socket), do: save_note(socket, note)
  def handle_event("save_note", %{"value" => note}, socket), do: save_note(socket, note)

  def handle_event("save_image_description", %{"link" => %{"image_description" => text}}, socket),
    do: save_image_description(socket, text)

  def handle_event("save_image_description", %{"value" => text}, socket), do: save_image_description(socket, text)

  # Triage: suggestions are accepted or dismissed one by one, from a card or
  # the link column; "accept all" and ✓ finish the link.
  def handle_event("accept_suggestion", %{"id" => id}, socket) do
    case Collections.accept_suggestion(socket.assigns.current_scope, id) do
      {:ok, _collection} -> {:noreply, socket}
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, gettext("Not found."))}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, gettext("Couldn't create that collection."))}
    end
  end

  def handle_event("dismiss_suggestion", %{"id" => id}, socket) do
    case Collections.dismiss_suggestion(socket.assigns.current_scope, id) do
      :ok -> {:noreply, socket}
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, gettext("Not found."))}
    end
  end

  def handle_event("accept_all", %{"id" => id}, socket) do
    with {:ok, link} <- own_link(socket, id),
         {:ok, link} <- Collections.accept_all_suggestions(socket.assigns.current_scope, link) do
      {:noreply, triaged(socket, link)}
    else
      {:error, :not_found} -> {:noreply, gone(socket)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, gettext("Couldn't create that collection."))}
    end
  end

  def handle_event("finish", %{"id" => id}, socket) do
    with {:ok, link} <- own_link(socket, id),
         {:ok, link} <- Collections.finish_triage(socket.assigns.current_scope, link) do
      {:noreply, triaged(socket, link)}
    else
      {:error, :not_found} -> {:noreply, gone(socket)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, gettext("Couldn't finish this link."))}
    end
  end

  def handle_event("delete", _params, socket) do
    case Library.delete_link(socket.assigns.current_scope, socket.assigns.link) do
      {:ok, link} ->
        socket = socket |> stream_delete(:links, link) |> refresh_counts()
        {:noreply, push_patch(socket, to: list_path(socket.assigns))}

      {:error, :not_found} ->
        {:noreply, gone(socket)}
    end
  end

  # Attaches the finished upload to the open link as its first image.
  defp handle_progress(:screenshot, %{done?: true}, socket) do
    socket = track_screenshot_link(socket)

    results = consume_uploaded_entries(socket, :screenshot, fn %{path: path}, _entry -> {:ok, File.read(path)} end)

    case {results, socket.assigns.link} do
      {[{:ok, binary}], %{id: id} = link} when is_binary(binary) and id == socket.assigns.screenshot_link_id ->
        attach_screenshot(socket, link, binary)

      {_results, _link} ->
        {:noreply, assign(socket, :screenshot_link_id, nil)}
    end
  end

  defp handle_progress(:screenshot, _entry, socket), do: {:noreply, track_screenshot_link(socket)}

  # Entries are cancelled whenever the open link changes, so one that is
  # still around belongs to the link open now.
  defp track_screenshot_link(%{assigns: %{screenshot_link_id: nil, link: %{id: id}}} = socket),
    do: assign(socket, :screenshot_link_id, id)

  defp track_screenshot_link(socket), do: socket

  defp attach_screenshot(socket, link, binary) do
    case Library.attach_screenshot(socket.assigns.current_scope, link, binary) do
      {:ok, link} -> {:noreply, socket |> restream(link) |> refresh_open(link)}
      {:error, :not_an_image} -> {:noreply, put_flash(socket, :error, gettext("That file isn't an image."))}
      {:error, :too_large} -> {:noreply, put_flash(socket, :error, gettext("That image is too large."))}
      {:error, :not_found} -> {:noreply, gone(socket)}
      {:error, %Ecto.Changeset{}} -> {:noreply, put_flash(socket, :error, gettext("That image couldn't be added."))}
    end
  end

  defp open_search(socket) do
    q =
      case socket.assigns.filter do
        {:search, q, _id} -> q
        _other -> ""
      end

    assign(socket, search_form: search_form(q), add_form: nil)
  end

  defp invalid_link_error, do: {dgettext_noop("errors", "That doesn't look like a link."), []}

  defp add_error(socket, url, error), do: assign(socket, :add_form, to_form(%{"url" => url}, errors: [url: error]))

  defp add_link(socket, url) when byte_size(url) > @max_url_bytes,
    do: {:noreply, add_error(socket, "", invalid_link_error())}

  defp add_link(socket, url) do
    case Library.save_link(socket.assigns.current_scope, url) do
      {:ok, link, :created} ->
        {:noreply,
         socket
         |> assign(:add_form, nil)
         |> put_flash(:info, gettext("Saved."))
         |> push_patch(to: ~p"/inbox/l/#{link.id}")}

      {:ok, link, :existing} ->
        {:noreply,
         socket
         |> assign(:add_form, nil)
         |> put_flash(:info, gettext("Already in your archive."))
         |> push_patch(to: existing_path(link))}

      {:error, :invalid_url} ->
        {:noreply, add_error(socket, url, invalid_link_error())}

      {:error, %Ecto.Changeset{errors: errors}} ->
        error =
          case errors do
            [{_field, error} | _] -> error
            _ -> invalid_link_error()
          end

        {:noreply, add_error(socket, url, error)}
    end
  end

  defp add_links(socket, urls) do
    case Library.save_links(socket.assigns.current_scope, urls) do
      %{created: [], existing: []} ->
        {:noreply, add_error(socket, "", invalid_link_error())}

      %{created: created, existing: existing, invalid: invalid} ->
        summary =
          [
            created != [] && saved_count(length(created)),
            existing != [] && already_saved_count(length(existing)),
            invalid != [] && invalid_count(length(invalid))
          ]
          |> Enum.filter(& &1)
          |> Enum.join(" · ")

        {:noreply, socket |> assign(:add_form, nil) |> put_flash(:info, summary)}
    end
  end

  # A new link waits in the inbox; a saved one opens where it lives.
  defp existing_path(%{triaged_at: nil} = link), do: ~p"/inbox/l/#{link.id}"
  defp existing_path(link), do: ~p"/all/l/#{link.id}"

  defp own_link(socket, id) do
    {:ok, Library.get_link!(socket.assigns.current_scope, id)}
  rescue
    _ in [Ecto.NoResultsError, CastError] -> {:error, :not_found}
  end

  # A finished link leaves the inbox (sliding out, see `inbox_item/1`), and
  # its column closes; elsewhere it just updates in place.
  defp triaged(socket, link) do
    socket = socket |> restream(link) |> refresh_counts()

    cond do
      socket.assigns.filter == :inbox and open?(socket, link) -> push_patch(socket, to: ~p"/inbox")
      open?(socket, link) -> refresh_open(socket, link)
      true -> socket
    end
  end

  defp own_collection(socket, id), do: Enum.find(socket.assigns.collections, &(&1.id == id))

  # A link removed from the collection being viewed no longer belongs in that
  # list, so close it.
  defp left_collection(%{assigns: %{live_action: action, collection: %{id: id, slug: slug}}} = socket, %{id: id})
       when action in [:collection_link, :collection_link_web], do: push_patch(socket, to: ~p"/c/#{slug}")

  defp left_collection(socket, _collection), do: socket

  # The link column follows `{:link_updated, link}`, which adding broadcasts.
  defp add_to(socket, collection) do
    case Collections.add_link(socket.assigns.current_scope, collection, socket.assigns.link) do
      :ok -> {:noreply, assign(socket, :collection_filter, collection_filter(""))}
      {:error, :not_found} -> {:noreply, gone(socket)}
    end
  end

  # Adds the link to the collection with that name, creating it if needed.
  defp pick_or_create(socket, name) do
    name = String.trim(name)

    case {name, Collections.find_by_name_or_slug(socket.assigns.collections, name)} do
      {"", _collection} ->
        {:noreply, socket}

      {_name, %Collection{} = collection} ->
        add_to(socket, collection)

      {name, nil} ->
        case Collections.create_collection(socket.assigns.current_scope, %{"name" => name}) do
          {:ok, collection} -> add_to(socket, collection)
          {:error, _changeset} -> {:noreply, assign(socket, :collection_filter, picker_error(name))}
        end
    end
  end

  defp create_collection(socket, attrs) do
    case Collections.create_collection(socket.assigns.current_scope, attrs) do
      {:ok, collection} ->
        {:noreply, socket |> assign(:new_collection_form, nil) |> push_patch(to: ~p"/c/#{collection.slug}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :new_collection_form, to_form(changeset))}
    end
  end

  # `{:collections_changed}` then refreshes the column and follows a new slug.
  defp save_collection(socket, attrs) do
    case Collections.update_collection(socket.assigns.current_scope, socket.assigns.collection, attrs) do
      {:ok, _collection} -> {:noreply, assign(socket, editing: nil, collection_form: nil)}
      {:error, :not_found} -> {:noreply, socket |> put_flash(:error, gettext("Not found.")) |> push_patch(to: ~p"/")}
      {:error, changeset} -> {:noreply, assign(socket, :collection_form, to_form(changeset))}
    end
  end

  defp save_note(%{assigns: %{link: link}} = socket, note) do
    if note == (link.note || "") do
      {:noreply, socket}
    else
      case Library.update_note(socket.assigns.current_scope, link, %{note: note}) do
        {:ok, link} -> {:noreply, socket |> assign(link: link, note_form: note_form(link)) |> show_note_saved()}
        {:error, :not_found} -> {:noreply, gone(socket)}
        {:error, changeset} -> {:noreply, assign(socket, :note_form, to_form(changeset, as: :link, action: :validate))}
      end
    end
  end

  defp save_ai_notes(%{assigns: %{link: link}} = socket, text) do
    if text == (link.ai_notes || "") do
      {:noreply, socket}
    else
      case Library.update_ai_notes(socket.assigns.current_scope, link, %{ai_notes: text}) do
        {:ok, link} ->
          {:noreply, socket |> assign(link: link, ai_notes_form: ai_notes_form(link)) |> show_saved(:ai_notes_saved)}

        {:error, :not_found} ->
          {:noreply, gone(socket)}

        {:error, changeset} ->
          {:noreply, assign(socket, :ai_notes_form, to_form(changeset, as: :link, action: :validate))}
      end
    end
  end

  defp relate(socket, id) do
    case Library.relate(socket.assigns.current_scope, socket.assigns.link, id) do
      {:ok, _relation} -> {:noreply, assign(socket, relation_filter: relation_filter(""), relation_options: nil)}
      {:error, reason} when reason in [:self, :duplicate] -> {:noreply, socket}
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, gettext("Not found."))}
    end
  end

  defp save_image_description(%{assigns: %{link: link}} = socket, text) do
    if text == (link.image_description || "") do
      {:noreply, socket}
    else
      case Library.update_image_description(socket.assigns.current_scope, link, %{image_description: text}) do
        {:ok, link} ->
          {:noreply,
           socket |> assign(link: link, description_form: description_form(link)) |> show_saved(:description_saved)}

        {:error, :not_found} ->
          {:noreply, gone(socket)}

        {:error, changeset} ->
          {:noreply, assign(socket, :description_form, to_form(changeset, as: :link, action: :validate))}
      end
    end
  end

  # "Saved" shows briefly; a newer save restarts the timer, so only the
  # latest one clears it.
  defp show_note_saved(socket), do: show_saved(socket, :note_saved)

  defp show_saved(socket, key) do
    ref = make_ref()
    Process.send_after(self(), {:clear_saved, key, ref}, @note_saved_ms)
    assign(socket, key, ref)
  end

  defp gone(socket) do
    socket |> put_flash(:error, gettext("Not found.")) |> push_patch(to: list_path(socket.assigns))
  end

  @impl true
  def handle_info({:link_created, link}, socket),
    do: {:noreply, socket |> insert_new(link) |> refresh_counts() |> refresh_home([link])}

  # A paste of several links arrives at once, refreshing the counts once.
  def handle_info({:links_created, links}, socket),
    do: {:noreply, links |> Enum.reduce(socket, &insert_new(&2, &1)) |> refresh_counts() |> refresh_home(links)}

  def handle_info({:link_updated, %{id: id}}, socket) do
    socket = refresh_counts(socket)

    case fetch_link(socket, %{"id" => id}) do
      {:ok, link} ->
        before = socket.assigns.link

        {:noreply,
         socket
         |> restream(link)
         |> refresh_open(link)
         |> refresh_related(before, link)
         |> refresh_similar_source(link)
         |> settle_snapshot(link)
         |> settle_notes(link)
         |> refresh_home([link])}

      {:error, :not_found, _to} ->
        {:noreply, socket}
    end
  end

  # A requested snapshot that failed, from this page or another one showing
  # the same link.
  def handle_info({:snapshot_failed, %{id: id}}, socket) do
    if Map.has_key?(socket.assigns.snapshot_requests, id) or open?(socket, %{id: id}) do
      {:noreply,
       socket
       |> update(:snapshot_requests, &Map.delete(&1, id))
       |> put_flash(:error, gettext("Couldn't generate the image."))}
    else
      {:noreply, socket}
    end
  end

  # Notes the user asked for (or automatic ones on the open link) that
  # failed, from this page or another one showing the same link.
  def handle_info({:notes_failed, %{id: id}}, socket) do
    if Map.has_key?(socket.assigns.notes_requests, id) or open?(socket, %{id: id}) do
      {:noreply,
       socket
       |> update(:notes_requests, &Map.delete(&1, id))
       |> put_flash(:error, gettext("Couldn't write the notes."))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:relations_changed, ids}, socket) do
    if Enum.any?(ids, &open?(socket, %{id: &1})), do: {:noreply, reload_related(socket)}, else: {:noreply, socket}
  end

  def handle_info({:link_deleted, link}, socket) do
    socket = socket |> stream_delete(:links, link) |> refresh_counts() |> refresh_home([link])
    socket = if link.id in related_ids(socket), do: reload_related(socket), else: socket

    if open?(socket, link) do
      {:noreply, push_patch(socket, to: list_path(socket.assigns))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:collections_changed}, socket) do
    socket = socket |> refresh_counts() |> reload_home()

    case socket.assigns.collection do
      nil ->
        {:noreply, socket}

      current ->
        case Enum.find(socket.assigns.collections, &(&1.id == current.id)) do
          nil -> {:noreply, push_patch(socket, to: collection_gone_path(socket.assigns))}
          %{slug: slug} = collection when slug == current.slug -> {:noreply, assign(socket, :collection, collection)}
          collection -> {:noreply, push_patch(socket, to: renamed_path(socket.assigns, collection))}
        end
    end
  end

  # Only the import column shows imports.
  def handle_info({:import_updated, import}, socket) do
    if socket.assigns.live_action == :import, do: send_update(ImportComponent, id: "import", import: import)
    {:noreply, socket}
  end

  def handle_info({:clear_saved, key, ref}, socket) when key in [:note_saved, :description_saved, :ai_notes_saved] do
    if socket.assigns[key] == ref, do: {:noreply, assign(socket, key, nil)}, else: {:noreply, socket}
  end

  @impl true
  def handle_async(:search, {:ok, {filter, %{links: links, partial: partial}}}, %{assigns: %{filter: filter}} = socket) do
    {:noreply,
     socket
     |> assign(search_loading: false, search_partial: partial, search_count: length(links))
     |> stream(:links, links, reset: true)}
  end

  # The page left the search (or moved to another query) before this result
  # arrived: it is dropped, and the spinner stops unless a newer search runs.
  def handle_async(:search, {:ok, _stale}, socket) do
    if results?(socket.assigns.filter),
      do: {:noreply, socket},
      else: {:noreply, reset_search(socket)}
  end

  # A crash keeps the cards, flagged like a partial result.
  def handle_async(:search, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, search_loading: false, search_partial: true)}

  def handle_async(:embeddable, {:ok, {:ok, link}}, socket),
    do: {:noreply, socket |> assign(:web_check, nil) |> refresh_open(link)}

  def handle_async(:embeddable, _failed, %{assigns: %{web_check: {:checking, id}}} = socket),
    do: {:noreply, assign(socket, :web_check, {:failed, id})}

  def handle_async(:embeddable, _failed, socket), do: {:noreply, socket}

  # A requested snapshot is done once the link has a snapshot it did not
  # have when it was requested.
  defp settle_snapshot(socket, link) do
    case Map.fetch(socket.assigns.snapshot_requests, link.id) do
      {:ok, before} ->
        if MapSet.subset?(snapshot_ids(link), before),
          do: socket,
          else: update(socket, :snapshot_requests, &Map.delete(&1, link.id))

      :error ->
        socket
    end
  end

  defp snapshot_ids(link), do: for(%{kind: :snapshot, id: id} <- link.images, into: MapSet.new(), do: id)

  # Requested notes are done once the link has notes newer than it had when
  # they were requested.
  defp settle_notes(socket, link) do
    case Map.fetch(socket.assigns.notes_requests, link.id) do
      {:ok, before} when before != link.ai_notes_at -> update(socket, :notes_requests, &Map.delete(&1, link.id))
      _waiting -> socket
    end
  end

  # The open link's similar links change once it is embedded again, and a
  # listed link may have a new title or image.
  defp refresh_related(socket, before, link) do
    embedded? = selected?(before, link) and before.embedded_at != link.embedded_at
    if embedded? or link.id in related_ids(socket), do: reload_related(socket), else: socket
  end

  # The similar list's title follows its link.
  defp refresh_similar_source(%{assigns: %{similar_source: %{id: id}}} = socket, %{id: id} = link),
    do: socket |> assign(similar_source: link) |> assign_page_title()

  defp refresh_similar_source(socket, _link), do: socket

  # The home reloads only the columns a link event touches: the inbox and the
  # collections the links belong to now, and the columns that listed them
  # before. Reloading every column would be cheap too, but capture alone
  # broadcasts several updates per saved link. Columns keep the navigation's
  # order; one left empty is dropped.
  defp refresh_home(%{assigns: %{home_columns: nil}} = socket, _links), do: socket

  defp refresh_home(socket, links) do
    ids = MapSet.new(links, & &1.id)
    columns = socket.assigns.home_columns
    listed = for column <- columns, Enum.any?(column.links, &MapSet.member?(ids, &1.id)), do: home_key(column)
    belongs = Enum.flat_map(links, &[if(is_nil(&1.triaged_at), do: :inbox) | Enum.map(&1.collections, fn c -> c.id end)])

    case Enum.uniq(listed ++ belongs) -- [nil] do
      [] ->
        socket

      keys ->
        fresh = Library.home_columns(socket.assigns.current_scope, only: keys)
        by_key = Map.new(Enum.reject(columns, &(home_key(&1) in keys)) ++ fresh, &{home_key(&1), &1})
        order = [:inbox | Enum.map(socket.assigns.collections, & &1.id)]
        assign(socket, :home_columns, for(key <- order, column = by_key[key], do: column))
    end
  end

  # Renamed, deleted or new collections reload the whole home.
  defp reload_home(%{assigns: %{home_columns: nil}} = socket), do: socket
  defp reload_home(socket), do: assign(socket, :home_columns, Library.home_columns(socket.assigns.current_scope))

  defp home_key(%{kind: :inbox}), do: :inbox
  defp home_key(%{collection: %{id: id}}), do: id

  defp insert_new(socket, link) do
    if matches?(socket.assigns.filter, link), do: stream_insert(socket, :links, link, at: 0), else: socket
  end

  defp collection_gone_path(%{filter: {:search, q, _id}}), do: search_path(q, nil)
  defp collection_gone_path(_assigns), do: ~p"/"

  defp renamed_path(%{link: nil} = assigns, collection), do: list_path(%{assigns | collection: collection})

  defp renamed_path(%{link: link, web?: true} = assigns, collection), do: web_path(assigns.filter, collection, link)

  defp renamed_path(%{link: link} = assigns, collection), do: link_path(assigns.filter, collection, link)

  # Search results only change by searching again: updates refresh the cards
  # already listed.
  defp restream(%{assigns: %{filter: filter}} = socket, link) when elem(filter, 0) in [:search, :similar],
    do: stream_insert(socket, :links, link, update_only: true)

  defp restream(socket, link) do
    if matches?(socket.assigns.filter, link),
      do: stream_insert(socket, :links, link),
      else: stream_delete(socket, :links, link)
  end

  defp refresh_open(socket, link) do
    if open?(socket, link),
      do:
        socket
        |> assign(
          link: link,
          note_form: note_form(link),
          description_form: description_form(link),
          ai_notes_form: ai_notes_form(link)
        )
        |> refresh_reader(link)
        |> assign_page_title(),
      else: socket
  end

  defp refresh_reader(%{assigns: %{web?: true}} = socket, link), do: load_reader(socket, link)
  defp refresh_reader(socket, _link), do: socket

  defp open?(socket, link), do: selected?(socket.assigns.link, link)

  defp matches?(nil, _link), do: false
  defp matches?(:all, _link), do: true
  defp matches?(:inbox, link), do: is_nil(link.triaged_at)
  defp matches?({:collection, id}, link), do: Enum.any?(link.collections, &(&1.id == id))
  defp matches?({:search, _q, _id}, _link), do: false
  defp matches?({:similar, _id}, _link), do: false

  defp refresh_counts(socket) do
    scope = socket.assigns.current_scope
    collections = Collections.list_collections(scope)

    assign(socket,
      total_count: Library.count_links(scope),
      inbox_count: Library.count_inbox(scope),
      collections: collections,
      collections_count: length(collections)
    )
  end

  defp assign_page_title(%{assigns: %{link: %{} = link}} = socket), do: assign(socket, :page_title, display_title(link))

  defp assign_page_title(%{assigns: %{live_action: :guide}} = socket), do: assign(socket, :page_title, gettext("Guide"))

  defp assign_page_title(%{assigns: %{live_action: :import}} = socket),
    do: assign(socket, :page_title, gettext("Import bookmarks"))

  defp assign_page_title(socket) do
    %{filter: filter, collection: collection, similar_source: source} = socket.assigns
    assign(socket, :page_title, list_title(filter, collection, source) || "Acervo")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="columns" class="columns" phx-hook=".Shortcuts">
        <.column id="column-root" class="column-root" reveal={false}>
          <.column_head title="Acervo" level="h1" />
          <p class="lead" phx-no-format>
            {gettext("Good things I find on the internet.")}
            <.count_link id="lead-all" patch={~p"/all"} count={@total_count}>{links_count(@total_count)}</.count_link> · {collections_count(@collections_count)}<%= if @inbox_count > 0 do %> · <.count_link id="lead-inbox" patch={~p"/inbox"} count={@inbox_count}>{inbox_waiting(@inbox_count)}</.count_link><% end %>.
          </p>
          <ul class="nav">
            <.nav_item
              id="nav-inbox"
              navigate={~p"/inbox"}
              active={@filter == :inbox}
              dot={@inbox_count > 0}
              count={@inbox_count}
            >
              {gettext("Inbox")}
            </.nav_item>
            <.nav_item id="nav-all" navigate={~p"/all"} active={@filter == :all} count={@total_count}>
              {gettext("All")}
            </.nav_item>
            <li class="nav-sep" aria-hidden="true"></li>
            <.nav_item
              :for={collection <- @collections}
              id={"nav-collection-#{collection.id}"}
              navigate={~p"/c/#{collection.slug}"}
              active={@filter == {:collection, collection.id}}
              count={collection.link_count}
            >
              {collection.name}
            </.nav_item>
            <li :if={is_nil(@new_collection_form)}>
              <.icon_button
                id="new-collection"
                variant="nav"
                icon="lucide-plus"
                label={gettext("New collection")}
                phx-click="new_collection"
              />
            </li>
            <li :if={@new_collection_form}>
              <.form
                for={@new_collection_form}
                id="new-collection-form"
                class="nav-form"
                phx-change="validate_new_collection"
                phx-submit="create_collection"
              >
                <.input
                  field={@new_collection_form[:name]}
                  id="new-collection-name"
                  class="nav-input"
                  placeholder={gettext("New collection")}
                  aria-label={gettext("New collection")}
                  maxlength="80"
                  autocomplete="off"
                  phx-mounted={JS.focus()}
                  phx-blur="create_collection"
                  phx-keydown="cancel_new_collection"
                  phx-key="Escape"
                />
              </.form>
            </li>
          </ul>
        </.column>

        <div
          :if={@home_columns not in [nil, []]}
          id="home-columns"
          class="home-columns"
          phx-hook=".HomeScroll"
        >
          <.column
            :for={column <- @home_columns}
            :key={home_column_id(column)}
            id={home_column_id(column)}
            title={home_column_title(column)}
            narrow
            reveal={false}
          >
            <:actions><span class="column-count">{column.count}</span></:actions>
            <div class="cards cards-compact">
              <.card
                :for={link <- column.links}
                :key={link.id}
                id={"#{home_column_id(column)}-link-#{link.id}"}
                link={link}
                patch={home_link_path(column, link)}
                compact
              />
              <.link
                id={"#{home_column_id(column)}-all"}
                class="see-all"
                patch={home_list_path(column)}
              >
                {gettext("See all (%{count})", count: column.count)}
              </.link>
            </div>
          </.column>
        </div>

        <.column
          :if={@filter}
          id={list_column_id(@filter)}
          title={list_title(@filter, @collection, @similar_source)}
        >
          <:heading :if={@editing == :name}>
            <.form
              for={@collection_form}
              id="rename-collection-form"
              class="title-form"
              phx-change="validate_collection"
              phx-submit="save_collection"
            >
              <.input
                field={@collection_form[:name]}
                id="rename-collection-name"
                class="title-input"
                aria-label={gettext("Name")}
                maxlength="80"
                autocomplete="off"
                phx-mounted={JS.focus()}
                phx-blur="save_collection"
                phx-keydown="cancel_edit"
                phx-key="Escape"
              />
            </.form>
          </:heading>
          <:actions :if={match?({:collection, _id}, @filter)}><.collection_menu /></:actions>
          <:actions :if={@search_partial and match?({:search, _q, _id}, @filter)}>
            <span
              id="search-partial"
              class="search-partial"
              role="img"
              title={gettext("Only matching words")}
              aria-label={gettext("Only matching words")}
            >
              <.icon name="lucide-zap-off" class="size-4" />
            </span>
          </:actions>
          <.form
            :if={@editing == :description}
            for={@collection_form}
            id="describe-collection-form"
            class="desc desc-form"
            phx-change="validate_collection"
            phx-submit="save_collection"
          >
            <.input
              type="textarea"
              field={@collection_form[:description]}
              id="describe-collection-text"
              class="desc-input"
              rows="1"
              maxlength="280"
              placeholder={gettext("Add a description")}
              aria-label={gettext("Description")}
              phx-mounted={JS.focus()}
              phx-blur="save_collection"
              phx-keydown="cancel_edit"
              phx-key="Escape"
            />
          </.form>
          <p :if={@editing != :description and list_desc(@filter, @collection)} class="desc">
            {list_desc(@filter, @collection)}
          </p>
          <div
            :if={results?(@filter)}
            id="search-status"
            role="status"
            aria-live="polite"
            aria-atomic="true"
          >
            <.empty :if={@search_count == 0} id="search-empty">{gettext("Nothing found.")}</.empty>
            <span :if={@search_count && @search_count > 0} class="sr-only">
              {results_count(@search_count)}
            </span>
          </div>
          <div id="links" class="cards" phx-update="stream">
            <.empty id="links-empty" class="hidden only:block">{empty_text(@filter)}</.empty>
            <%= for {id, link} <- @streams.links do %>
              <.inbox_item
                :if={@filter == :inbox}
                id={id}
                link={link}
                patch={link_path(@filter, @collection, link)}
                selected={selected?(@link, link)}
              />
              <.card
                :if={@filter != :inbox}
                id={id}
                link={link}
                patch={link_path(@filter, @collection, link)}
                selected={selected?(@link, link)}
              />
            <% end %>
          </div>
        </.column>

        <.column
          :if={@link}
          id="column-link"
          class="column-link"
          title={display_title(@link)}
          key={@link.id}
        >
          <.link_detail
            link={@link}
            note_form={@note_form}
            collections={@collections}
            collection_filter={@collection_filter}
            upload={@uploads.screenshot}
            snapshots={@snapshots?}
            snapshot_busy={Map.has_key?(@snapshot_requests, @link.id)}
            ai_notes_form={@ai_notes_form}
            ai_notes_saved={!!@ai_notes_saved}
            notes_busy={Map.has_key?(@notes_requests, @link.id)}
            related={related_result(@related)}
            related_path={&link_path(@filter, @collection, &1)}
            similar_path={similar_path(@link)}
            relation_filter={@relation_filter}
            relation_options={@relation_options}
            note_saved={!!@note_saved}
            description_form={@description_form}
            description_saved={!!@description_saved}
            web_path={web_toggle_path(assigns, @link)}
            web_open={@web?}
          />
        </.column>

        <.column
          :if={@web? and @link}
          id="column-web"
          class="column-web"
          title={site_title(@link)}
          key={@link.id}
        >
          <:actions>
            <div class="head-acts">
              <.icon_button
                :if={reader_toggle?(@link, @reader)}
                id="web-reader-toggle"
                variant="head"
                icon={if @reader_view?, do: "lucide-globe", else: "lucide-book-open"}
                label={reader_toggle_label(@reader_view?)}
                patch={reader_toggle_path(assigns, @link)}
              />
              <.icon_button
                id="web-open"
                variant="head"
                icon="lucide-external-link"
                label={gettext("Open original")}
                href={Embed.original_url(@link)}
                target="_blank"
                rel="noopener noreferrer"
              />
              <.icon_button
                id="web-close"
                variant="head"
                icon="lucide-x"
                label={gettext("Close")}
                patch={link_path(@filter, @collection, @link)}
              />
            </div>
          </:actions>
          <.web_view
            link={@link}
            check={@web_check}
            content={@reader && @reader.html}
            reader={@reader_view?}
          />
        </.column>

        <.column :if={@live_action == :guide} id="column-guide" title={gettext("Guide")}>
          <.guide snapshots={@snapshots?} />
        </.column>

        <.column :if={@live_action == :import} id="column-import" title={gettext("Import bookmarks")}>
          <.live_component module={ImportComponent} id="import" current_scope={@current_scope} />
        </.column>
      </div>
      <.add_pill :if={@add_form} form={@add_form} />
      <.search_pill
        :if={@search_form}
        form={@search_form}
        scope={@search_scope}
        loading={@search_loading}
      />
      <.dock
        active={dock_active(@filter)}
        inbox_count={@inbox_count}
        adding={!!@add_form}
        searching={!!@search_form}
        locale={@locale}
        return_to={@return_to}
        auto_notes={@current_scope.user.auto_notes}
      />
    </Layouts.app>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".HomeScroll">
      // The home opens at its start, the root column, wherever the row was
      // scrolled before. Its columns don't scroll the row on their own
      // (`reveal={false}`), so links arriving later don't move it either.
      export default {
        mounted() { this.el.closest('.columns')?.scrollTo({left: 0}) }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Shortcuts">
      // Page-wide keys, ignored while typing in a field:
      // - pasting text with links saves every one of them. Only links that
      //   start with http(s):// or www. count, so stray pasted words are never
      //   saved; the dock's add field still takes bare hosts. A list pasted
      //   in that field is saved the same way, since a one-line input would
      //   glue its lines together. Pasted images are handled by the link
      //   column's own hook.
      // - `?` opens the guide.
      // - `/` opens the search pill, or focuses it.
      // - Esc closes the web view column, unless a menu or a pill is open:
      //   those close first, on their own.
      // And one key that works in fields too: ⌘K (Ctrl+K) toggles the search
      // pill, or focuses it when it is open but not focused.
      const HAS_LINK = /(https?:\/\/|\bwww\.)\S+\.\S{2,}/i
      // The server finds the links; long text is cut at a space, so no link
      // arrives cut in half.
      const MAX_TEXT = 20000
      const bound = text => {
        if (text.length <= MAX_TEXT) return text
        const cut = text.slice(0, MAX_TEXT)
        const space = cut.search(/\s\S*$/)
        return space > 0 ? cut.slice(0, space) : cut
      }
      const typing = target => target instanceof Element &&
        (target.closest('input, textarea, select, [contenteditable]') || target.isContentEditable)
      const plain = event => !(event.ctrlKey || event.metaKey || event.altKey)
      export default {
        mounted() {
          this.onKeydown = event => {
            if (event.defaultPrevented || event.isComposing) return
            if (this.searchShortcut(event)) return this.toggleSearch(event)
            if (typing(event.target)) return
            if (event.key === 'Escape') return this.closeWeb(event)
            if (event.key === '/' && plain(event) && !document.querySelector('.popover[open]')) return this.openSearch(event)
            if (event.key !== '?' || !plain(event)) return
            event.preventDefault()
            this.pushEvent('open_guide', {})
          }
          this.searchShortcut = event => {
            if (event.key.toLowerCase() !== 'k' || event.altKey || event.shiftKey) return false
            const mac = document.documentElement.dataset.platform === 'mac'
            return mac ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey
          }
          this.focusSearch = () => document.getElementById('search-query')?.focus()
          this.openSearch = event => {
            event.preventDefault()
            this.pushEvent('open_search', {}, this.focusSearch)
          }
          this.toggleSearch = event => {
            const input = document.getElementById('search-query')
            if (input && document.activeElement !== input) return this.openSearch(event)
            event.preventDefault()
            this.pushEvent('toggle_search', {}, this.focusSearch)
          }
          this.closeWeb = event => {
            if (!document.getElementById('column-web')) return
            if (document.querySelector('#add-pill, #search-pill, .popover[open]')) return
            event.preventDefault()
            this.pushEvent('close_web', {})
          }
          this.onPaste = event => {
            const addField = event.target instanceof Element && event.target.id === 'add-link-url'
            if (typing(event.target) && !addField) return
            const data = event.clipboardData
            if (!data) return
            if (Array.from(data.files || []).some(file => file.type.startsWith('image/'))) return
            const text = data.getData('text/plain')
            if (addField && !/[\r\n]/.test(text.trim())) return
            if (!HAS_LINK.test(text)) return
            event.preventDefault()
            this.pushEvent('add_link', {url: bound(text)})
          }
          window.addEventListener('paste', this.onPaste)
          window.addEventListener('keydown', this.onKeydown)
        },
        destroyed() {
          window.removeEventListener('paste', this.onPaste)
          window.removeEventListener('keydown', this.onKeydown)
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :patch, :string, required: true
  attr :count, :integer, required: true
  slot :inner_block, required: true

  # Counts link to their list, except a zero that has nothing to show.
  defp count_link(%{count: 0} = assigns), do: ~H"{render_slot(@inner_block)}"

  defp count_link(assigns) do
    ~H"""
    <.link id={@id} patch={@patch}>{render_slot(@inner_block)}</.link>
    """
  end

  defp home_column_id(%{kind: :inbox}), do: "home-inbox"
  defp home_column_id(%{collection: collection}), do: "home-collection-#{collection.id}"

  defp home_column_title(%{kind: :inbox}), do: gettext("Inbox")
  defp home_column_title(%{collection: collection}), do: collection.name

  defp home_link_path(%{kind: :inbox}, link), do: ~p"/inbox/l/#{link.id}"
  defp home_link_path(%{collection: collection}, link), do: ~p"/c/#{collection.slug}/l/#{link.id}"

  defp home_list_path(%{kind: :inbox}), do: ~p"/inbox"
  defp home_list_path(%{collection: collection}), do: ~p"/c/#{collection.slug}"

  defp list_column_id(:all), do: "column-all"
  defp list_column_id(:inbox), do: "column-inbox"
  defp list_column_id({:collection, _id}), do: "column-collection"
  defp list_column_id({:search, _q, _id}), do: "column-search"
  defp list_column_id({:similar, _id}), do: "column-similar"

  defp list_title(:all, _collection, _source), do: gettext("All")
  defp list_title(:inbox, _collection, _source), do: gettext("Inbox")
  defp list_title({:collection, _id}, collection, _source), do: collection.name
  defp list_title({:search, q, _id}, _collection, _source), do: if(short_query?(q), do: gettext("Search"), else: q)
  defp list_title({:similar, _id}, _collection, source), do: gettext("Similar to %{title}", title: display_title(source))
  defp list_title(nil, _collection, _source), do: nil

  # Search and similar lists come from a query, with a status line.
  defp results?(filter), do: is_tuple(filter) and elem(filter, 0) in [:search, :similar]

  defp related_result(%AsyncResult{ok?: true, result: result}), do: result
  defp related_result(_loading), do: nil

  defp similar_path(link), do: with_query(~p"/search/l/#{link.id}", similar: link.id)

  defp list_desc(:all, _collection), do: gettext("Everything you saved, newest first.")
  defp list_desc(:inbox, _collection), do: gettext("Links waiting for a place.")
  defp list_desc({:collection, _id}, collection), do: collection.description
  defp list_desc({:search, _q, _id}, _collection), do: nil
  defp list_desc({:similar, _id}, _collection), do: nil

  defp empty_text(:inbox), do: gettext("Nothing waiting.")
  defp empty_text(:all), do: gettext("Nothing saved yet.")
  defp empty_text({:collection, _id}), do: gettext("Nothing here yet.")
  # A search says "Nothing found." itself, once its results arrive.
  defp empty_text({:search, _q, _id}), do: nil
  defp empty_text({:similar, _id}), do: nil

  defp list_path(%{filter: :inbox}), do: ~p"/inbox"
  defp list_path(%{filter: {:collection, _id}, collection: collection}), do: ~p"/c/#{collection.slug}"
  defp list_path(%{filter: {:search, q, _id}, collection: collection}), do: search_path(q, collection)
  defp list_path(%{filter: {:similar, id}}), do: with_query(~p"/search", similar: id)
  defp list_path(_assigns), do: ~p"/all"

  defp link_path(:inbox, _collection, link), do: ~p"/inbox/l/#{link.id}"
  defp link_path({:collection, _id}, collection, link), do: ~p"/c/#{collection.slug}/l/#{link.id}"

  defp link_path({:search, q, _id}, collection, link),
    do: with_query(~p"/search/l/#{link.id}", search_params(q, collection))

  defp link_path({:similar, id}, _collection, link), do: with_query(~p"/search/l/#{link.id}", similar: id)
  defp link_path(_filter, _collection, link), do: ~p"/all/l/#{link.id}"

  defp web_path(filter, collection, link, extra \\ [])
  defp web_path(:inbox, _collection, link, extra), do: with_query(~p"/inbox/l/#{link.id}/web", extra)

  defp web_path({:collection, _id}, collection, link, extra),
    do: with_query(~p"/c/#{collection.slug}/l/#{link.id}/web", extra)

  defp web_path({:search, q, _id}, collection, link, extra),
    do: with_query(~p"/search/l/#{link.id}/web", search_params(q, collection) ++ extra)

  defp web_path({:similar, id}, _collection, link, extra),
    do: with_query(~p"/search/l/#{link.id}/web", [similar: id] ++ extra)

  defp web_path(_filter, _collection, link, extra), do: with_query(~p"/all/l/#{link.id}/web", extra)

  defp search_path(q, collection), do: with_query(~p"/search", search_params(q, collection))

  defp search_params(q, collection) do
    Enum.reject([q: q, in: collection && collection.slug], fn {_key, value} -> value in [nil, ""] end)
  end

  defp with_query(path, []), do: path
  defp with_query(path, params), do: path <> "?" <> URI.encode_query(params)

  defp dock_active({:search, _q, _id}), do: :search
  defp dock_active({:similar, _id}), do: :search
  defp dock_active(:inbox), do: :inbox
  defp dock_active(_filter), do: :home

  # pt_BR treats 0 as singular; no results say "Nothing found." instead.
  defp results_count(count), do: ngettext("One result", "%{count} results", count)

  # The link column's image opens the web view column, and closes it again.
  defp web_toggle_path(%{web?: true} = assigns, link), do: link_path(assigns.filter, assigns.collection, link)
  defp web_toggle_path(assigns, link), do: web_path(assigns.filter, assigns.collection, link)

  # A framed page with an article toggles between the two, by `?view=reader`.
  defp reader_toggle?(link, %{html: html}) when is_binary(html), do: match?({:page, _url}, Embed.frame(link))
  defp reader_toggle?(_link, _reader), do: false

  defp reader_toggle_path(%{reader_view?: true} = assigns, link), do: web_path(assigns.filter, assigns.collection, link)

  defp reader_toggle_path(assigns, link), do: web_path(assigns.filter, assigns.collection, link, view: "reader")

  defp reader_toggle_label(true = _reader_view?), do: gettext("Show page")
  defp reader_toggle_label(false), do: gettext("Show reader view")

  defp selected?(%{id: id}, %{id: id}), do: true
  defp selected?(_open, _link), do: false

  defp return_to(uri) do
    %URI{path: path, query: query} = URI.parse(uri)
    path <> if(query, do: "?" <> query, else: "")
  end

  # pt_BR treats 0 as singular, so zero gets its own wording.
  defp links_count(0), do: gettext("No links")
  defp links_count(count), do: ngettext("One link", "%{count} links", count)

  defp collections_count(0), do: gettext("no collections")
  defp collections_count(count), do: ngettext("one collection", "%{count} collections", count)

  defp inbox_waiting(count), do: ngettext("one in the inbox", "%{count} in the inbox", count)

  # The summary of a paste of several links; zero counts are left out.
  defp saved_count(count), do: ngettext("%{count} link saved", "%{count} links saved", count)

  defp already_saved_count(count),
    do: ngettext("%{count} already in your archive", "%{count} already in your archive", count)

  defp invalid_count(count), do: ngettext("%{count} invalid", "%{count} invalid", count)
end
