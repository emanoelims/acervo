defmodule Acervo.Library do
  @moduledoc """
  Saved links, isolated per user.

  Saving a link enqueues `Acervo.Library.CaptureLink`, which fetches its
  preview in the background. Mutations broadcast on the `"links:<user_id>"`
  topic of `Acervo.PubSub`: `{:link_created, link}`, `{:link_updated, link}`
  and `{:link_deleted, link}`. Broadcast links carry their images,
  collections and pending collection suggestions preloaded.

  Preloaded images never carry their bytes, which are served separately
  through `Acervo.Storage.fetch/2`, and are only the card's: previews and
  screenshots. The reader view's images and HTML are loaded on their own by
  `reader_content/2`.
  """

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.AI.EnrichLink
  alias Acervo.Collections.CollectionLink
  alias Acervo.Collections.Suggestion
  alias Acervo.Library.CaptureLink
  alias Acervo.Library.Embed
  alias Acervo.Library.FramePolicy
  alias Acervo.Library.Images
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage
  alias Acervo.Library.SafeFetch
  alias Acervo.Library.URL
  alias Acervo.Repo
  alias Acervo.Search.EmbedLink
  alias Acervo.Storage
  alias Ecto.Multi

  @default_limit 60
  # Owner edits wait this many seconds before embedding, so a burst of them
  # collapses into one job.
  @embed_delay 5
  @image_fields LinkImage.__schema__(:fields) -- [:bytes]

  @type filter :: :all | :inbox | {:collection, Ecto.UUID.t()}

  @doc """
  Saves `url` for the scope's user. A URL whose canonical form is already
  saved, as a link's `canonical_url` or as the `resolved_url` its capture
  found, returns that link as `:existing`; otherwise the link is inserted with
  its capture job in one transaction and broadcast as `{:link_created, link}`.
  """
  @spec save_link(Scope.t(), String.t()) ::
          {:ok, Link.t(), :created | :existing} | {:error, :invalid_url | Ecto.Changeset.t()}
  def save_link(%Scope{user: user} = scope, url) when is_binary(url) do
    with {:ok, canonical_url} <- URL.normalize(url) do
      case find_saved(user, canonical_url) do
        %Link{} = link -> {:ok, preload_link(link), :existing}
        nil -> insert_link(scope, String.trim(url), canonical_url)
      end
    end
  end

  # `resolved_url` is not unique, so prefer the link saved under that exact
  # canonical URL, then the oldest.
  defp find_saved(user, canonical_url) do
    Repo.one(
      from l in Link,
        where: l.user_id == ^user.id and (l.canonical_url == ^canonical_url or l.resolved_url == ^canonical_url),
        order_by: [desc: l.canonical_url == ^canonical_url, asc: l.inserted_at, asc: l.id],
        limit: 1
    )
  end

  @doc false
  # Inserts a link for `canonical_url` with its capture job. Public only so
  # tests can exercise the lost race against a concurrent save.
  @spec insert_link(Scope.t(), String.t(), String.t()) ::
          {:ok, Link.t(), :created | :existing} | {:error, Ecto.Changeset.t()}
  def insert_link(%Scope{user: user} = scope, url, canonical_url) do
    changeset =
      Link.create_changeset(%Link{user_id: user.id}, %{
        url: url,
        canonical_url: canonical_url,
        source: URL.source(canonical_url)
      })

    Multi.new()
    |> Multi.insert(:link, changeset)
    |> Oban.insert(:job, fn %{link: link} -> CaptureLink.new(%{"link_id" => link.id}) end)
    |> Repo.transact()
    |> case do
      {:ok, %{link: link}} ->
        link = preload_link(link)
        broadcast(scope, {:link_created, link})
        {:ok, link, :created}

      {:error, :link, changeset, _changes} ->
        existing_after_race(user, canonical_url, changeset)
    end
  end

  # A concurrent save of the same URL wins the unique index; return its link.
  defp existing_after_race(user, canonical_url, changeset) do
    case Repo.get_by(Link, user_id: user.id, canonical_url: canonical_url) do
      %Link{} = link -> {:ok, preload_link(link), :existing}
      nil -> {:error, changeset}
    end
  end

  @doc """
  Lists the scope's links, newest first.

  ## Options

    * `:filter` - `:all` (default), `:inbox` (not yet triaged) or
      `{:collection, collection_id}`
    * `:limit` - defaults to #{@default_limit}

  Each link carries its collections, its pending collection suggestions and
  only its first image (position 0).
  """
  @spec list_links(Scope.t(), keyword()) :: [Link.t()]
  def list_links(%Scope{user: user}, opts \\ []) do
    opts = Keyword.validate!(opts, filter: :all, limit: @default_limit)
    first_image = from i in images_query(), where: i.position == 0

    from(l in Link,
      where: l.user_id == ^user.id,
      order_by: [desc: l.inserted_at, desc: l.id],
      limit: ^opts[:limit],
      preload: [:collections, images: ^first_image, suggestions: ^pending_suggestions_query()]
    )
    |> filter(opts[:filter])
    |> Repo.all()
  end

  @doc """
  The scope's links among `ids`, with the same preloads as `list_links/2`,
  in the order of `ids`. Ids of other users' links, or of deleted ones, are
  left out.
  """
  @spec list_links_by_ids(Scope.t(), [Ecto.UUID.t()]) :: [Link.t()]
  def list_links_by_ids(%Scope{}, []), do: []

  def list_links_by_ids(%Scope{user: user}, ids) when is_list(ids) do
    first_image = from i in images_query(), where: i.position == 0

    by_id =
      from(l in Link,
        where: l.user_id == ^user.id and l.id in ^ids,
        preload: [:collections, images: ^first_image, suggestions: ^pending_suggestions_query()]
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    for id <- ids, link = by_id[id], do: link
  end

  defp filter(query, :all), do: query
  defp filter(query, :inbox), do: where(query, [l], is_nil(l.triaged_at))

  defp filter(query, {:collection, collection_id}) do
    where(
      query,
      [l],
      l.id in subquery(from cl in CollectionLink, where: cl.collection_id == ^collection_id, select: cl.link_id)
    )
  end

  @doc "Gets one of the scope's links with its images, collections and pending suggestions. Raises if not found."
  @spec get_link!(Scope.t(), Ecto.UUID.t()) :: Link.t()
  def get_link!(%Scope{user: user}, id) do
    Link |> Repo.get_by!(id: id, user_id: user.id) |> preload_link()
  end

  @spec count_links(Scope.t()) :: non_neg_integer()
  def count_links(%Scope{user: user}) do
    Repo.aggregate(from(l in Link, where: l.user_id == ^user.id), :count)
  end

  @spec count_inbox(Scope.t()) :: non_neg_integer()
  def count_inbox(%Scope{user: user}) do
    Repo.aggregate(from(l in Link, where: l.user_id == ^user.id and is_nil(l.triaged_at)), :count)
  end

  @doc """
  Saves the owner's note. A changed note is embedded again for search
  (`Acervo.Search.EmbedLink`, after a short delay); an unchanged one costs
  nothing.
  """
  @spec update_note(Scope.t(), Link.t(), map()) :: {:ok, Link.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_note(%Scope{} = scope, %Link{} = link, attrs) do
    scope |> update_embedded(link, :note, &Link.note_changeset(&1, attrs)) |> updated(scope)
  end

  @doc "Returns a changeset for tracking note changes."
  @spec change_note(Link.t(), map()) :: Ecto.Changeset.t()
  def change_note(%Link{} = link, attrs \\ %{}), do: Link.note_changeset(link, attrs)

  @doc """
  Saves the owner's edit of the image description, stamping
  `image_description_edited_at` so enrichment never overwrites it.
  """
  @spec update_image_description(Scope.t(), Link.t(), map()) ::
          {:ok, Link.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_image_description(%Scope{} = scope, %Link{} = link, attrs) do
    scope
    |> update_embedded(link, :image_description, &Link.image_description_changeset(&1, attrs))
    |> updated(scope)
  end

  # Updates a field search embeds, under the link lock (checked against the
  # database), and enqueues the embedding when the field changed, in the
  # same transaction.
  defp update_embedded(%Scope{user: user}, %Link{id: id}, field, changeset_fun) do
    Repo.transact(fn ->
      case Repo.one(from l in Link, where: l.id == ^id and l.user_id == ^user.id, lock: "FOR NO KEY UPDATE") do
        nil -> {:error, :not_found}
        %Link{} = link -> link |> changeset_fun.() |> update_and_embed(field)
      end
    end)
  end

  defp update_and_embed(changeset, field) do
    with {:ok, link} <- Repo.update(changeset) do
      if Ecto.Changeset.changed?(changeset, field), do: embed(link), else: {:ok, link}
    end
  end

  defp embed(link) do
    with {:ok, _job} <- EmbedLink.enqueue(link, delay: @embed_delay), do: {:ok, %{link | embedding_status: :pending}}
  end

  @doc "Returns a changeset for tracking image description changes."
  @spec change_image_description(Link.t(), map()) :: Ecto.Changeset.t()
  def change_image_description(%Link{} = link, attrs \\ %{}), do: Link.image_description_changeset(link, attrs)

  @spec mark_triaged(Scope.t(), Link.t()) :: {:ok, Link.t()} | {:error, :not_found}
  def mark_triaged(%Scope{} = scope, %Link{} = link) do
    with {:ok, link} <- owned(scope, link) do
      link |> Ecto.Changeset.change(triaged_at: DateTime.utc_now(:second)) |> Repo.update() |> updated(scope)
    end
  end

  @spec delete_link(Scope.t(), Link.t()) :: {:ok, Link.t()} | {:error, :not_found}
  def delete_link(%Scope{} = scope, %Link{} = link) do
    with {:ok, link} <- owned(scope, link),
         {:ok, deleted} <- link |> preload_link() |> Repo.delete() do
      broadcast(scope, {:link_deleted, deleted})
      {:ok, deleted}
    end
  end

  @doc """
  Checks whether the link's page may be framed, for links captured before
  capture recorded it, and stores the answer in `embeddable`.

  The page is fetched through `Acervo.Library.SafeFetch` and judged from its
  final URL and headers by `Acervo.Library.FramePolicy`. A fetch that will not
  succeed on retry (see `Acervo.Library.CaptureLink.classify/1`) stores
  `false`; a transient failure stores nothing and is returned.
  """
  @spec check_embeddable(Scope.t(), Link.t()) :: {:ok, Link.t()} | {:error, :not_found | term()}
  def check_embeddable(%Scope{} = scope, %Link{} = link) do
    with {:ok, link} <- owned(scope, link),
         {:ok, embeddable} <- fetch_embeddable(Embed.original_url(link)) do
      link |> Link.capture_changeset(%{embeddable: embeddable}) |> Repo.update() |> updated(scope)
    end
  end

  defp fetch_embeddable(url) do
    case SafeFetch.get(url, accept: "text/html,application/xhtml+xml") do
      {:ok, response} ->
        {:ok, FramePolicy.embeddable?(response.url, response.headers)}

      {:error, reason} ->
        case CaptureLink.classify(reason) do
          :permanent -> {:ok, false}
          :transient -> {:error, reason}
        end
    end
  end

  @doc """
  Normalizes `binary` and stores it as the link's screenshot at position 0,
  moving its other images down. The link becomes `:ready` without an error
  and is enqueued for enrichment again, even when it was enriched: the image
  changed.
  """
  @spec attach_screenshot(Scope.t(), Link.t(), binary()) ::
          {:ok, Link.t()} | {:error, :not_found | :not_an_image | :too_large | Ecto.Changeset.t()}
  def attach_screenshot(%Scope{} = scope, %Link{} = link, binary) when is_binary(binary) do
    with {:ok, link} <- owned(scope, link),
         {:ok, image} <- Images.normalize(binary) do
      fn -> insert_screenshot(scope, link, image) end
      |> Repo.transact()
      |> updated(scope)
    end
  end

  defp insert_screenshot(scope, link, image) do
    Repo.update_all(from(i in LinkImage, where: i.link_id == ^link.id and i.kind != :content), inc: [position: 1])

    with {:ok, _image} <- Storage.put(scope, link, Map.merge(image, %{kind: :screenshot, position: 0})) do
      # `enqueue/1` marks the row `:pending`; the struct must say so too, or
      # the broadcast hides the waiting placeholder.
      changeset =
        link
        |> Link.capture_changeset(%{status: :ready, capture_error: nil})
        |> Ecto.Changeset.change(enrichment_status: :pending)

      with {:ok, link} <- Repo.update(changeset),
           {:ok, _job} <- EnrichLink.enqueue(link) do
        {:ok, link}
      end
    end
  end

  @doc """
  The link's reader HTML, sanitized at capture by `Acervo.Library.Sanitizer`
  and safe to render raw, or `nil` when it has none.
  """
  @spec reader_content(Scope.t(), Link.t()) :: String.t() | nil
  def reader_content(%Scope{user: user}, %Link{id: id}) do
    Repo.one(from l in Link, where: l.id == ^id and l.user_id == ^user.id, select: l.content_html)
  end

  @doc "Subscribes the caller to the scope's link broadcasts."
  @spec subscribe(Scope.t()) :: :ok | {:error, term()}
  def subscribe(%Scope{user: user}), do: Phoenix.PubSub.subscribe(Acervo.PubSub, topic(user.id))

  @doc false
  # Re-reads a link with its preloads and broadcasts `{:link_updated, link}`.
  # Used by `Acervo.Library.CaptureLink` and `Acervo.Collections`; returns
  # `:error` if the link is gone.
  @spec broadcast_updated(Scope.t(), Ecto.UUID.t()) :: :ok | :error
  def broadcast_updated(%Scope{user: user} = scope, link_id) do
    case Repo.get_by(Link, id: link_id, user_id: user.id) do
      %Link{} = link ->
        broadcast(scope, {:link_updated, preload_link(link)})

      nil ->
        :error
    end
  end

  @doc false
  # Preloads a link just written by the caller, broadcasts
  # `{:link_updated, link}` and returns it. Used by `Acervo.Collections`
  # after its transactions commit.
  @spec broadcast_link(Scope.t(), Link.t()) :: Link.t()
  def broadcast_link(%Scope{} = scope, %Link{} = link) do
    {:ok, link} = updated({:ok, link}, scope)
    link
  end

  # Checks ownership against the database, not the (possibly stale) struct.
  defp owned(%Scope{user: user}, %Link{id: id}) do
    case Repo.get_by(Link, id: id, user_id: user.id) do
      %Link{} = link -> {:ok, link}
      nil -> {:error, :not_found}
    end
  end

  defp updated({:ok, %Link{} = link}, scope) do
    link = preload_link(link)
    broadcast(scope, {:link_updated, link})
    {:ok, link}
  end

  defp updated({:error, _} = error, _scope), do: error

  defp preload_link(%Link{} = link) do
    Repo.preload(link, [:collections, images: images_query(), suggestions: pending_suggestions_query()], force: true)
  end

  # Only pending suggestions reach the interface, oldest first, with their
  # collection (nil for a new name).
  defp pending_suggestions_query do
    from s in Suggestion, where: s.status == :pending, order_by: [asc: s.inserted_at, asc: s.id], preload: :collection
  end

  defp images_query, do: from(i in LinkImage, where: i.kind != :content, select: struct(i, ^@image_fields))

  defp broadcast(%Scope{user: user}, message) do
    Phoenix.PubSub.broadcast(Acervo.PubSub, topic(user.id), message)
  end

  defp topic(user_id), do: "links:#{user_id}"
end
