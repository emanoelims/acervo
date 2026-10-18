defmodule AcervoWeb.ArchiveLive do
  @moduledoc """
  The column browser: root navigation, the selected list of links and the
  open link. Subscribes to the user's link broadcasts and keeps the list,
  the open link and the counts current.
  """
  use AcervoWeb, :live_view

  import AcervoWeb.LinkComponents

  alias Acervo.Collections
  alias Acervo.Library

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Library.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(filter: nil, collection: nil, link: nil, note_form: nil)
     |> refresh_counts()
     |> stream_configure(:links, dom_id: &"link-#{&1.id}")
     |> stream(:links, [])}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket = assign(socket, :return_to, return_to(uri))

    with {:ok, collection} <- fetch_collection(socket, params),
         filter = filter(socket.assigns.live_action, collection),
         reset? = filter != socket.assigns.filter or renamed?(socket.assigns.collection, collection),
         socket = socket |> assign(:collection, collection) |> apply_filter(filter, reset?),
         {:ok, link} <- fetch_link(socket, params) do
      {:noreply, socket |> select_link(link, reset?) |> assign_page_title()}
    else
      {:error, :not_found, to} ->
        {:noreply, socket |> put_flash(:error, gettext("Not found.")) |> push_patch(to: to)}
    end
  end

  defp fetch_collection(socket, %{"slug" => slug}) do
    {:ok, Collections.get_collection_by_slug!(socket.assigns.current_scope, slug)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found, ~p"/"}
  end

  defp fetch_collection(_socket, _params), do: {:ok, nil}

  defp fetch_link(socket, %{"id" => id}) do
    {:ok, Library.get_link!(socket.assigns.current_scope, id)}
  rescue
    _ in [Ecto.NoResultsError, Ecto.Query.CastError] -> {:error, :not_found, list_path(socket.assigns)}
  end

  defp fetch_link(_socket, _params), do: {:ok, nil}

  defp filter(action, _collection) when action in [:all, :all_link], do: :all
  defp filter(action, _collection) when action in [:inbox, :inbox_link], do: :inbox
  defp filter(action, collection) when action in [:collection, :collection_link], do: {:collection, collection.id}
  defp filter(:home, _collection), do: nil

  # A renamed collection changes the cards' hrefs, so it re-streams too.
  defp renamed?(%{id: id, slug: old}, %{id: id, slug: new}), do: old != new
  defp renamed?(_old, _new), do: false

  # Re-streams only when the list changes, so opening a link keeps the cards.
  defp apply_filter(socket, _filter, false), do: socket

  defp apply_filter(socket, nil, true), do: socket |> assign(:filter, nil) |> stream(:links, [], reset: true)

  defp apply_filter(socket, filter, true) do
    links = Library.list_links(socket.assigns.current_scope, filter: filter)
    socket |> assign(:filter, filter) |> stream(:links, links, reset: true)
  end

  # A reset stream renders every card with the new selection already; otherwise
  # the previously and newly selected cards are re-rendered in place. (Inserting
  # them after a reset in the same render would move them to the end.)
  defp select_link(socket, link, true = _reset?), do: assign(socket, link: link, note_form: link && note_form(link))

  defp select_link(socket, link, false = _reset?) do
    previous = socket.assigns.link

    socket
    |> assign(link: link, note_form: link && note_form(link))
    |> restream_existing(previous)
    |> restream_existing(link)
  end

  defp restream_existing(socket, nil), do: socket
  defp restream_existing(socket, link), do: stream_insert(socket, :links, link, update_only: true)

  defp note_form(link, attrs \\ %{}), do: to_form(Library.change_note(link, attrs), as: :link)

  @impl true
  def handle_event(event, _params, %{assigns: %{link: nil}} = socket) when event in ~w(save_note done delete),
    do: {:noreply, socket}

  def handle_event("save_note", %{"link" => %{"note" => note}}, socket), do: save_note(socket, note)
  def handle_event("save_note", %{"value" => note}, socket), do: save_note(socket, note)

  def handle_event("done", _params, socket) do
    inbox? = socket.assigns.live_action == :inbox_link

    case Library.mark_triaged(socket.assigns.current_scope, socket.assigns.link) do
      {:ok, link} when inbox? ->
        {:noreply, socket |> stream_delete(:links, link) |> refresh_counts() |> push_patch(to: ~p"/inbox")}

      {:ok, link} ->
        {:noreply, socket |> assign(:link, link) |> stream_insert(:links, link, update_only: true) |> refresh_counts()}

      {:error, :not_found} ->
        {:noreply, gone(socket)}
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

  defp save_note(%{assigns: %{link: link}} = socket, note) do
    if note == (link.note || "") do
      {:noreply, socket}
    else
      case Library.update_note(socket.assigns.current_scope, link, %{note: note}) do
        {:ok, link} -> {:noreply, assign(socket, link: link, note_form: note_form(link))}
        {:error, :not_found} -> {:noreply, gone(socket)}
        {:error, changeset} -> {:noreply, assign(socket, :note_form, to_form(changeset, as: :link, action: :validate))}
      end
    end
  end

  defp gone(socket) do
    socket |> put_flash(:error, gettext("Not found.")) |> push_patch(to: list_path(socket.assigns))
  end

  @impl true
  def handle_info({:link_created, link}, socket) do
    socket = if matches?(socket.assigns.filter, link), do: stream_insert(socket, :links, link, at: 0), else: socket
    {:noreply, refresh_counts(socket)}
  end

  def handle_info({:link_updated, %{id: id}}, socket) do
    socket =
      case fetch_link(socket, %{"id" => id}) do
        {:ok, link} -> socket |> restream(link) |> refresh_open(link)
        {:error, :not_found, _to} -> socket
      end

    {:noreply, refresh_counts(socket)}
  end

  def handle_info({:link_deleted, link}, socket) do
    socket = socket |> stream_delete(:links, link) |> refresh_counts()

    if open?(socket, link) do
      {:noreply, push_patch(socket, to: list_path(socket.assigns))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:collections_changed}, socket) do
    socket = refresh_counts(socket)

    case socket.assigns.collection do
      nil ->
        {:noreply, socket}

      current ->
        case Enum.find(socket.assigns.collections, &(&1.id == current.id)) do
          nil -> {:noreply, push_patch(socket, to: ~p"/")}
          %{slug: slug} = collection when slug == current.slug -> {:noreply, assign(socket, :collection, collection)}
          collection -> {:noreply, push_patch(socket, to: renamed_path(socket.assigns, collection))}
        end
    end
  end

  defp renamed_path(%{link: nil} = assigns, collection), do: list_path(%{assigns | collection: collection})

  defp renamed_path(%{link: link} = assigns, collection), do: link_path(assigns.filter, collection, link)

  defp restream(socket, link) do
    if matches?(socket.assigns.filter, link),
      do: stream_insert(socket, :links, link),
      else: stream_delete(socket, :links, link)
  end

  defp refresh_open(socket, link) do
    if open?(socket, link),
      do: socket |> assign(link: link, note_form: note_form(link)) |> assign_page_title(),
      else: socket
  end

  defp open?(socket, link), do: selected?(socket.assigns.link, link)

  defp matches?(nil, _link), do: false
  defp matches?(:all, _link), do: true
  defp matches?(:inbox, link), do: is_nil(link.triaged_at)
  defp matches?({:collection, id}, link), do: Enum.any?(link.collections, &(&1.id == id))

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

  defp assign_page_title(socket) do
    assign(socket, :page_title, list_title(socket.assigns.filter, socket.assigns.collection) || "Acervo")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="columns" class="columns">
        <.column id="column-root" class="column-root">
          <h1 class="root-title">Acervo</h1>
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
            <li :if={@collections != []} class="nav-sep" aria-hidden="true"></li>
            <.nav_item
              :for={collection <- @collections}
              id={"nav-collection-#{collection.id}"}
              navigate={~p"/c/#{collection.slug}"}
              active={@filter == {:collection, collection.id}}
              count={collection.link_count}
            >
              {collection.name}
            </.nav_item>
          </ul>
        </.column>

        <.column :if={@filter} id={list_column_id(@filter)} title={list_title(@filter, @collection)}>
          <p :if={list_desc(@filter, @collection)} class="desc">{list_desc(@filter, @collection)}</p>
          <div id="links" class="cards" phx-update="stream">
            <.empty id="links-empty" class="hidden only:block">{empty_text(@filter)}</.empty>
            <.card
              :for={{id, link} <- @streams.links}
              id={id}
              link={link}
              patch={link_path(@filter, @collection, link)}
              selected={selected?(@link, link)}
            />
          </div>
        </.column>

        <.column
          :if={@link}
          id="column-link"
          class="column-link"
          title={display_title(@link)}
          key={@link.id}
        >
          <.link_detail link={@link} note_form={@note_form} />
        </.column>
      </div>
      <.dock
        active={if @filter == :inbox, do: :inbox, else: :home}
        inbox_count={@inbox_count}
        locale={@locale}
        return_to={@return_to}
      />
    </Layouts.app>
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

  defp list_column_id(:all), do: "column-all"
  defp list_column_id(:inbox), do: "column-inbox"
  defp list_column_id({:collection, _id}), do: "column-collection"

  defp list_title(:all, _collection), do: gettext("All")
  defp list_title(:inbox, _collection), do: gettext("Inbox")
  defp list_title({:collection, _id}, collection), do: collection.name
  defp list_title(nil, _collection), do: nil

  defp list_desc(:all, _collection), do: gettext("Everything you saved, newest first.")
  defp list_desc(:inbox, _collection), do: gettext("Links waiting for a place.")
  defp list_desc({:collection, _id}, collection), do: collection.description

  defp empty_text(:inbox), do: gettext("Nothing waiting.")
  defp empty_text(:all), do: gettext("Nothing saved yet.")
  defp empty_text({:collection, _id}), do: gettext("Nothing here yet.")

  defp list_path(%{filter: :inbox}), do: ~p"/inbox"
  defp list_path(%{filter: {:collection, _id}, collection: collection}), do: ~p"/c/#{collection.slug}"
  defp list_path(_assigns), do: ~p"/all"

  defp link_path(:inbox, _collection, link), do: ~p"/inbox/l/#{link.id}"
  defp link_path({:collection, _id}, collection, link), do: ~p"/c/#{collection.slug}/l/#{link.id}"
  defp link_path(_filter, _collection, link), do: ~p"/all/l/#{link.id}"

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
end
