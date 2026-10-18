defmodule AcervoWeb.ArchiveLive do
  @moduledoc """
  The column browser: root navigation, the selected list of links and the
  open link. Subscribes to the user's link broadcasts and keeps the list,
  the open link and the counts current.

  Links are saved from the dock's pill or by pasting anywhere, and organized
  into collections from the link column; collections are created in column 1
  and renamed, described or deleted from their column's menu.
  """
  use AcervoWeb, :live_view

  import AcervoWeb.LinkComponents

  alias Acervo.Collections
  alias Acervo.Collections.Collection
  alias Acervo.Library

  @max_screenshot_bytes 15_000_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Library.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(filter: nil, collection: nil, link: nil, note_form: nil)
     |> assign(add_form: nil, new_collection_form: nil, editing: nil, collection_form: nil)
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

    with {:ok, collection} <- fetch_collection(socket, params),
         filter = filter(socket.assigns.live_action, collection),
         reset? = filter != socket.assigns.filter or renamed?(socket.assigns.collection, collection),
         socket = socket |> stop_editing(collection) |> assign(:collection, collection) |> apply_filter(filter, reset?),
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

  # Leaving a collection drops its rename or description form.
  defp stop_editing(%{assigns: %{collection: %{id: id}}} = socket, %{id: id}), do: socket
  defp stop_editing(socket, _collection), do: assign(socket, editing: nil, collection_form: nil)

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
  defp select_link(socket, link, true = _reset?), do: assign_link(socket, link)

  defp select_link(socket, link, false = _reset?) do
    previous = socket.assigns.link

    socket
    |> assign_link(link)
    |> restream_existing(previous)
    |> restream_existing(link)
  end

  defp assign_link(socket, link) do
    assign(socket, link: link, note_form: link && note_form(link), collection_filter: collection_filter(""))
  end

  defp restream_existing(socket, nil), do: socket
  defp restream_existing(socket, link), do: stream_insert(socket, :links, link, update_only: true)

  defp note_form(link, attrs \\ %{}), do: to_form(Library.change_note(link, attrs), as: :link)

  defp collection_filter(query), do: to_form(%{"query" => query})

  defp picker_error(query),
    do: to_form(%{"query" => query}, errors: [query: {gettext("Couldn't create that collection."), []}])

  @max_url_bytes 2048
  @link_events ~w(save_note done delete add_to_collection remove_from_collection create_collection_for_link pick_collection)
  @collection_events ~w(edit_collection validate_collection save_collection delete_collection)

  @impl true
  def handle_event(event, _params, %{assigns: %{link: nil}} = socket) when event in @link_events, do: {:noreply, socket}

  def handle_event(event, _params, %{assigns: %{collection: nil}} = socket) when event in @collection_events,
    do: {:noreply, socket}

  # The screenshot upload starts on its own; a new pick replaces a failed one.
  def handle_event("validate_screenshot", _params, socket) do
    case socket.assigns.uploads.screenshot.entries do
      [_one] -> {:noreply, socket}
      entries -> {:noreply, Enum.reduce(Enum.drop(entries, -1), socket, &cancel_upload(&2, :screenshot, &1.ref))}
    end
  end

  # Adding a link: the dock's pill and pasting anywhere share "add_link".
  def handle_event("toggle_add", _params, %{assigns: %{add_form: nil}} = socket),
    do: {:noreply, assign(socket, :add_form, to_form(%{"url" => ""}))}

  def handle_event(event, _params, socket) when event in ~w(toggle_add close_add),
    do: {:noreply, assign(socket, :add_form, nil)}

  # Nothing legitimate is this long; don't echo it back into the input.
  def handle_event("add_link", %{"url" => url}, socket) when is_binary(url) and byte_size(url) > @max_url_bytes,
    do: {:noreply, add_error(socket, "", invalid_link_error())}

  def handle_event("add_link", %{"url" => url}, socket) when is_binary(url) do
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

  def handle_event("add_link", _params, socket), do: {:noreply, socket}

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

  # Attaches the finished upload to the open link as its first image.
  defp handle_progress(:screenshot, %{done?: true}, socket) do
    results = consume_uploaded_entries(socket, :screenshot, fn %{path: path}, _entry -> {:ok, File.read(path)} end)

    case {results, socket.assigns.link} do
      {[{:ok, binary}], %{} = link} when is_binary(binary) -> attach_screenshot(socket, link, binary)
      {_results, _link} -> {:noreply, socket}
    end
  end

  defp handle_progress(:screenshot, _entry, socket), do: {:noreply, socket}

  defp attach_screenshot(socket, link, binary) do
    case Library.attach_screenshot(socket.assigns.current_scope, link, binary) do
      {:ok, link} -> {:noreply, socket |> restream(link) |> refresh_open(link)}
      {:error, :not_an_image} -> {:noreply, put_flash(socket, :error, gettext("That file isn't an image."))}
      {:error, :too_large} -> {:noreply, put_flash(socket, :error, gettext("That image is too large."))}
      {:error, :not_found} -> {:noreply, gone(socket)}
      {:error, %Ecto.Changeset{}} -> {:noreply, put_flash(socket, :error, gettext("That file isn't an image."))}
    end
  end

  defp invalid_link_error, do: {dgettext_noop("errors", "That doesn't look like a link."), []}

  defp add_error(socket, url, error), do: assign(socket, :add_form, to_form(%{"url" => url}, errors: [url: error]))

  # A new link waits in the inbox; a saved one opens where it lives.
  defp existing_path(%{triaged_at: nil} = link), do: ~p"/inbox/l/#{link.id}"
  defp existing_path(link), do: ~p"/all/l/#{link.id}"

  defp own_collection(socket, id), do: Enum.find(socket.assigns.collections, &(&1.id == id))

  # A link removed from the collection being viewed no longer belongs in that
  # list, so close it.
  defp left_collection(%{assigns: %{live_action: :collection_link, collection: %{id: id, slug: slug}}} = socket, %{id: id}),
       do: push_patch(socket, to: ~p"/c/#{slug}")

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
      <div id="columns" class="columns" phx-hook=".PasteLink">
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
              <button
                id="new-collection"
                type="button"
                class="nav-add"
                phx-click="new_collection"
                title={gettext("New collection")}
                aria-label={gettext("New collection")}
              >
                <.icon name="lucide-plus" class="size-4" />
              </button>
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

        <.column :if={@filter} id={list_column_id(@filter)} title={list_title(@filter, @collection)}>
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
          <:actions :if={@collection}><.collection_menu /></:actions>
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
          <.link_detail
            link={@link}
            note_form={@note_form}
            collections={@collections}
            collection_filter={@collection_filter}
            upload={@uploads.screenshot}
          />
        </.column>
      </div>
      <.add_pill :if={@add_form} form={@add_form} />
      <.dock
        active={if @filter == :inbox, do: :inbox, else: :home}
        inbox_count={@inbox_count}
        adding={!!@add_form}
        locale={@locale}
        return_to={@return_to}
      />
    </Layouts.app>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PasteLink">
      // Pasting a link anywhere outside a field saves it. Pasted images are
      // handled by the link column's own hook.
      const URL_LIKE = /^(https?:\/\/)?[^\s]+\.[^\s]{2,}$/
      export default {
        mounted() {
          this.onPaste = event => {
            const target = event.target
            if (target instanceof Element &&
                (target.closest('input, textarea, [contenteditable]') || target.isContentEditable)) return
            const data = event.clipboardData
            if (!data) return
            if (Array.from(data.files || []).some(file => file.type.startsWith('image/'))) return
            const url = data.getData('text/plain').trim()
            if (url.length > 2048 || !URL_LIKE.test(url)) return
            event.preventDefault()
            this.pushEvent('add_link', {url})
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
