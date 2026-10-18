defmodule Acervo.Collections do
  @moduledoc """
  Manual collections and link membership, isolated per user.

  Mutations broadcast on the `"links:<user_id>"` topic of `Acervo.PubSub`:
  `{:collections_changed}` when collections change and `{:link_updated, link}`,
  with the link's images and collections preloaded, when a link's membership
  changes.

  It also owns collection suggestions (`Acervo.Collections.Suggestion`), which
  come from the model and are untrusted: they are stored only after their
  targets are checked against the user's collections in the database, and
  they apply only when the owner accepts them. Broadcasts are sent after the
  transaction commits.
  """

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.Collections.Collection
  alias Acervo.Collections.CollectionLink
  alias Acervo.Collections.Suggestion
  alias Acervo.Library
  alias Acervo.Library.Link
  alias Acervo.Repo
  alias Acervo.Search.EmbedLink

  # Owner edits wait this many seconds before embedding (see
  # `Acervo.Search.EmbedLink`).
  @embed_delay 5

  @doc """
  Lists the user's collections ordered by position then name. Each one carries
  a virtual `link_count`, computed in the same query.
  """
  def list_collections(%Scope{user: user}) do
    Repo.all(
      from c in Collection,
        where: c.user_id == ^user.id,
        order_by: [asc: c.position, asc: c.name],
        select_merge: %{
          link_count:
            fragment(
              "(SELECT count(*) FROM collection_links cl WHERE cl.collection_id = ?)",
              c.id
            )
        }
    )
  end

  @doc """
  Finds, among `collections`, the one `name` would collide with: the one with
  that name, ignoring case, or with the slug it would get. `nil` when it would
  be new.
  """
  def find_by_name_or_slug(collections, name) do
    name = String.trim(name)
    slug = Collection.slugify(name)
    Enum.find(collections, &(String.downcase(&1.name) == String.downcase(name) or &1.slug == slug))
  end

  def get_collection_by_slug!(%Scope{user: user}, slug) do
    Repo.get_by!(Collection, user_id: user.id, slug: slug)
  end

  def change_collection(%Collection{} = collection, attrs \\ %{}) do
    Collection.changeset(collection, attrs)
  end

  def create_collection(%Scope{user: user} = scope, attrs) do
    %Collection{user_id: user.id}
    |> Collection.changeset(attrs)
    |> Repo.insert()
    |> broadcast_collections_changed(scope)
  end

  @doc """
  Updates the collection with the same id, re-fetched from the database for the
  scope's user (the given struct may be stale). Returns `{:ok, collection}`,
  `{:error, changeset}`, or `{:error, :not_found}` when the collection does not
  exist or belongs to another user.
  """
  @spec update_collection(Scope.t(), Collection.t(), map()) ::
          {:ok, Collection.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def update_collection(%Scope{} = scope, %Collection{} = collection, attrs) do
    with {:ok, collection} <- owned(scope, collection) do
      collection
      |> Collection.changeset(attrs)
      |> update_and_embed()
      |> broadcast_collections_changed(scope)
    end
  end

  # Search embeds collection names, not descriptions.
  defp update_and_embed(%Ecto.Changeset{valid?: true, data: collection} = changeset) do
    if Ecto.Changeset.changed?(changeset, :name),
      do: with_members_embedded(collection, fn -> Repo.update(changeset) end),
      else: Repo.update(changeset)
  end

  defp update_and_embed(changeset), do: Repo.update(changeset)

  @doc """
  Deletes the collection with the same id, re-fetched from the database for the
  scope's user. Its links are kept. Returns `{:ok, collection}`,
  `{:error, changeset}`, or `{:error, :not_found}` when the collection does not
  exist or belongs to another user.
  """
  @spec delete_collection(Scope.t(), Collection.t()) ::
          {:ok, Collection.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def delete_collection(%Scope{} = scope, %Collection{} = collection) do
    with {:ok, collection} <- owned(scope, collection) do
      collection
      |> with_members_embedded(fn -> Repo.delete(collection) end)
      |> broadcast_collections_changed(scope)
    end
  end

  # Runs `fun` (a rename or a delete of `collection`) in a transaction, after
  # locking, in id order, the links it holds and the links suggested into it,
  # then embeds its members again. Links first keeps the lock order of `finish_triage/2`
  # and `replace_suggestions/3`, which lock the link before its suggestions
  # (a delete cascades into both memberships and suggestions).
  defp with_members_embedded(%Collection{id: id}, fun) do
    Repo.transact(fn -> lock_and_embed_members(id, fun) end)
  end

  defp lock_and_embed_members(id, fun) do
    member_ids = Repo.all(from cl in CollectionLink, where: cl.collection_id == ^id, select: cl.link_id)
    suggested_ids = Repo.all(from s in Suggestion, where: s.collection_id == ^id, select: s.link_id)

    Repo.all(
      from l in Link,
        where: l.id in ^Enum.uniq(member_ids ++ suggested_ids),
        order_by: l.id,
        lock: "FOR NO KEY UPDATE",
        select: l.id
    )

    with {:ok, result} <- fun.(),
         {:ok, _count} <- EmbedLink.enqueue_many(member_ids, delay: @embed_delay) do
      {:ok, result}
    end
  end

  @doc """
  Adds a link to a collection. Idempotent. Returns `{:error, :not_found}` when
  either record does not belong to the scope's user.
  """
  def add_link(%Scope{} = scope, %Collection{} = collection, %Link{} = link) do
    change_membership(scope, collection, link, fn ->
      insert_membership(collection.id, link.id, :manual)
    end)
  end

  @doc """
  Removes a link from a collection. Idempotent. Returns `{:error, :not_found}`
  when either record does not belong to the scope's user.
  """
  def remove_link(%Scope{} = scope, %Collection{} = collection, %Link{} = link) do
    change_membership(scope, collection, link, fn ->
      {count, _} =
        Repo.delete_all(from cl in CollectionLink, where: cl.collection_id == ^collection.id and cl.link_id == ^link.id)

      count > 0
    end)
  end

  # Locks the link first (ownership checked in the database), then checks the
  # collection, runs `change` and, when it changed a membership, embeds the
  # link again. Broadcasts after commit. A link deleted meanwhile is
  # `:not_found`.
  defp change_membership(%Scope{user: user} = scope, collection, link, change) do
    fn ->
      with %Link{} <- lock_link(user, link.id) || {:error, :not_found},
           true <- owned_collection?(user, collection) || {:error, :not_found} do
        embed_if(change.(), link.id)
      end
    end
    |> Repo.transact()
    |> case do
      {:ok, _} -> broadcast_link_updated(scope, link)
      {:error, _} = error -> error
    end
  end

  defp embed_if(true = _changed?, link_id), do: EmbedLink.enqueue(link_id, delay: @embed_delay)
  defp embed_if(false = _changed?, _link_id), do: {:ok, :unchanged}

  # Returns whether a row was inserted: `on_conflict: :nothing` inserts none
  # when the link is already in the collection.
  defp insert_membership(collection_id, link_id, source) do
    {count, _} =
      Repo.insert_all(
        CollectionLink,
        [
          %{
            id: Ecto.UUID.generate(version: 7),
            collection_id: collection_id,
            link_id: link_id,
            source: source,
            inserted_at: DateTime.utc_now(:second)
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:collection_id, :link_id]
      )

    count == 1
  end

  @max_enrichment_collections 50
  @max_examples 3
  @max_example_length 120
  @max_suggestions 3

  @doc """
  The user's collections as enrichment input: at most
  #{@max_enrichment_collections}, ordered like `list_collections/1`, each with
  the titles of its #{@max_examples} newest links, clipped to
  #{@max_example_length} characters. Titles come from the web and are
  untrusted. `id` never reaches the model; the model sees slugs.
  """
  @type enrichment_collection :: %{
          id: Ecto.UUID.t(),
          slug: String.t(),
          name: String.t(),
          description: String.t() | nil,
          examples: [String.t()]
        }

  @spec list_for_enrichment(Scope.t()) :: [enrichment_collection()]
  def list_for_enrichment(%Scope{user: user}) do
    collections =
      Repo.all(
        from c in Collection,
          where: c.user_id == ^user.id,
          order_by: [asc: c.position, asc: c.name],
          limit: @max_enrichment_collections,
          select: %{id: c.id, slug: c.slug, name: c.name, description: c.description}
      )

    examples = examples(Enum.map(collections, & &1.id))
    Enum.map(collections, &Map.put(&1, :examples, Map.get(examples, &1.id, [])))
  end

  defp examples([]), do: %{}

  defp examples(collection_ids) do
    ranked =
      from cl in CollectionLink,
        join: l in Link,
        on: l.id == cl.link_id,
        where: cl.collection_id in ^collection_ids and not is_nil(l.title) and l.title != "",
        windows: [newest: [partition_by: cl.collection_id, order_by: [desc: l.inserted_at, desc: l.id]]],
        select: %{collection_id: cl.collection_id, title: l.title, rank: over(row_number(), :newest)}

    from(r in subquery(ranked), where: r.rank <= @max_examples, order_by: [asc: r.collection_id, asc: r.rank])
    |> Repo.all()
    |> Enum.group_by(& &1.collection_id, &String.slice(&1.title, 0, @max_example_length))
  end

  @type suggestion_attrs :: %{
          optional(:collection_id) => Ecto.UUID.t(),
          optional(:proposed_name) => String.t(),
          optional(:reason) => String.t() | nil
        }

  @doc """
  Replaces the link's pending suggestions with `entries`, in one transaction.
  Accepted and dismissed suggestions are kept.

  Entries are dropped when their `collection_id` is not one of the user's
  collections (checked in the database), when the link already belongs to
  the target, when the owner already accepted or dismissed that target for
  this link, or when they repeat an earlier entry. A `proposed_name` that
  matches one of the user's collections by name or slug becomes that
  collection. At most #{@max_suggestions} are kept. A triaged link gets none.
  Broadcasts nothing; the caller does.
  """
  @spec replace_suggestions(Scope.t(), Link.t(), [suggestion_attrs()]) ::
          {:ok, [Suggestion.t()]} | {:error, :not_found}
  def replace_suggestions(%Scope{user: user}, %Link{id: link_id}, entries) when is_list(entries) do
    Repo.transact(fn ->
      case lock_link(user, link_id) do
        nil -> {:error, :not_found}
        # Triaged links are out of the inbox: no new suggestions for them.
        %Link{triaged_at: %DateTime{}} -> {:ok, []}
        %Link{} = link -> {:ok, insert_suggestions(user, link, entries)}
      end
    end)
  end

  defp insert_suggestions(user, link, entries) do
    Repo.delete_all(from s in Suggestion, where: s.link_id == ^link.id and s.user_id == ^user.id and s.status == :pending)

    collections = Repo.all(from c in Collection, where: c.user_id == ^user.id)
    by_id = Map.new(collections, &{&1.id, &1})
    member_ids = MapSet.new(Repo.all(from cl in CollectionLink, where: cl.link_id == ^link.id, select: cl.collection_id))
    decided = decided_targets(link)

    entries
    |> Enum.flat_map(&resolve_target(&1, collections, by_id))
    |> Enum.reject(fn {target, _attrs} -> blocked?(target, member_ids, decided, by_id) end)
    |> Enum.uniq_by(fn {target, _attrs} -> target end)
    |> Enum.map(fn {_target, attrs} -> Suggestion.changeset(%Suggestion{user_id: user.id, link_id: link.id}, attrs) end)
    |> Enum.filter(& &1.valid?)
    |> Enum.take(@max_suggestions)
    |> Enum.map(&Repo.insert!/1)
    |> Repo.preload(:collection)
  end

  # Targets the owner already decided on for this link: `{:collection, id}`
  # and `{:name, normalized_name}`.
  defp decided_targets(link) do
    from(s in Suggestion,
      where: s.link_id == ^link.id and s.status in [:accepted, :dismissed],
      select: {s.collection_id, s.normalized_name}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {id, name} -> Enum.reject([id && {:collection, id}, name && {:name, name}], &is_nil/1) end)
    |> MapSet.new()
  end

  defp resolve_target(%{collection_id: id} = entry, _collections, by_id) when is_binary(id) do
    if Map.has_key?(by_id, id), do: [{{:collection, id}, %{collection_id: id, reason: entry[:reason]}}], else: []
  end

  defp resolve_target(%{proposed_name: name} = entry, collections, _by_id) when is_binary(name) do
    case find_by_name_or_slug(collections, name) do
      %Collection{id: id} ->
        [{{:collection, id}, %{collection_id: id, reason: entry[:reason]}}]

      nil ->
        case Collection.slugify(name) do
          "" -> []
          slug -> [{{:name, slug}, %{proposed_name: name, reason: entry[:reason]}}]
        end
    end
  end

  defp resolve_target(_entry, _collections, _by_id), do: []

  defp blocked?({:collection, id} = target, member_ids, decided, by_id) do
    MapSet.member?(member_ids, id) or MapSet.member?(decided, target) or
      MapSet.member?(decided, {:name, by_id[id].slug})
  end

  defp blocked?(target, _member_ids, decided, _by_id), do: MapSet.member?(decided, target)

  @doc """
  Accepts one of the user's pending suggestions: adds its link to the
  suggested collection, creating it for a new name (or reusing the user's
  collection with that name or slug), and marks it accepted.

  The user's other pending suggestions with the same name are repointed to
  that collection, or deleted when their link already has it. Broadcasts
  `{:collections_changed}` when a collection was created, and the accepted
  and repointed links, after commit.
  """
  @spec accept_suggestion(Scope.t(), Ecto.UUID.t()) :: {:ok, Collection.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def accept_suggestion(%Scope{user: user} = scope, id) do
    fn ->
      with {:ok, suggestion} <- lock_pending(user, id),
           {:ok, collection, created?} <- target_collection(user, suggestion),
           {:ok, _} <- add_suggested(collection, suggestion) do
        suggestion |> Ecto.Changeset.change(status: :accepted) |> Repo.update!()
        repointed = repoint(user, suggestion, collection)

        {:ok, %{collection: collection, created?: created?, link_ids: [suggestion.link_id | repointed]}}
      end
    end
    |> Repo.transact()
    |> case do
      {:ok, %{collection: collection, created?: created?, link_ids: link_ids}} ->
        if created?, do: broadcast(scope, {:collections_changed})
        link_ids |> Enum.uniq() |> Enum.each(&Library.broadcast_updated(scope, &1))
        {:ok, collection}

      {:error, _} = error ->
        error
    end
  end

  # The link first, then the suggestion, as `finish_triage/2` and
  # `replace_suggestions/3` do: the suggestion's link is read unlocked, the
  # link locked, and the suggestion locked and checked again.
  defp lock_pending(user, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         pending = from(s in Suggestion, where: s.id == ^id and s.user_id == ^user.id and s.status == :pending),
         link_id when is_binary(link_id) <- Repo.one(from s in pending, select: s.link_id),
         %Link{} <- lock_link(user, link_id),
         %Suggestion{link_id: ^link_id} = suggestion <- Repo.one(from s in pending, lock: "FOR UPDATE") do
      {:ok, suggestion}
    else
      _ -> {:error, :not_found}
    end
  end

  # A suggestion whose link joins the collection embeds the link again.
  defp add_suggested(collection, %Suggestion{link_id: link_id}) do
    collection.id |> insert_membership(link_id, :suggestion) |> embed_if(link_id)
  end

  defp target_collection(user, %Suggestion{collection_id: id}) when is_binary(id) do
    case Repo.get_by(Collection, id: id, user_id: user.id) do
      %Collection{} = collection -> {:ok, collection, false}
      nil -> {:error, :not_found}
    end
  end

  defp target_collection(user, %Suggestion{proposed_name: name, normalized_name: slug}) do
    case Repo.get_by(Collection, user_id: user.id, slug: slug) do
      %Collection{} = collection -> {:ok, collection, false}
      nil -> create_for_suggestion(user, name)
    end
  end

  # A concurrent creation of the same slug wins the unique index; on conflict
  # nothing is inserted (and the transaction stays usable), so re-read by slug.
  defp create_for_suggestion(user, name) do
    changeset = Collection.changeset(%Collection{user_id: user.id}, %{name: name})

    with {:ok, inserted} <- Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:user_id, :slug]) do
      collection = Repo.get_by!(Collection, user_id: user.id, slug: inserted.slug)
      {:ok, collection, collection.id == inserted.id}
    end
  end

  # Points the user's other pending new-name suggestions for this name at
  # `collection`. Those whose link already has the collection, as a member or
  # a pending suggestion, are deleted instead. Returns the affected link ids.
  defp repoint(user, suggestion, collection) do
    names = Enum.uniq(Enum.reject([suggestion.normalized_name, collection.slug], &is_nil/1))

    others =
      Repo.all(
        from s in Suggestion,
          where:
            s.user_id == ^user.id and s.status == :pending and is_nil(s.collection_id) and
              s.normalized_name in ^names and s.id != ^suggestion.id,
          order_by: [asc: s.inserted_at, asc: s.id],
          # Another session accepting one of these holds its lock; waiting
          # for it could deadlock, so that one is left as it is.
          lock: "FOR UPDATE SKIP LOCKED"
      )

    taken =
      MapSet.new(
        Repo.all(
          from s in Suggestion,
            where: s.user_id == ^user.id and s.status == :pending and s.collection_id == ^collection.id,
            select: s.link_id
        ) ++ Repo.all(from cl in CollectionLink, where: cl.collection_id == ^collection.id, select: cl.link_id)
      )

    {keep, drop} =
      others
      |> Enum.reduce({[], [], taken}, fn s, {keep, drop, taken} ->
        if MapSet.member?(taken, s.link_id),
          do: {keep, [s.id | drop], taken},
          else: {[s.id | keep], drop, MapSet.put(taken, s.link_id)}
      end)
      |> then(fn {keep, drop, _taken} -> {keep, drop} end)

    Repo.delete_all(from s in Suggestion, where: s.id in ^drop)

    Repo.update_all(from(s in Suggestion, where: s.id in ^keep),
      set: [collection_id: collection.id, updated_at: DateTime.utc_now(:second)]
    )

    others |> Enum.map(& &1.link_id) |> Enum.uniq()
  end

  @doc """
  Dismisses one of the user's pending suggestions and broadcasts its link.
  A dismissed target is never suggested again for that link.
  """
  @spec dismiss_suggestion(Scope.t(), Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def dismiss_suggestion(%Scope{user: user} = scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {1, [link_id]} <-
           Repo.update_all(
             from(s in Suggestion,
               where: s.id == ^id and s.user_id == ^user.id and s.status == :pending,
               select: s.link_id
             ),
             set: [status: :dismissed, updated_at: DateTime.utc_now(:second)]
           ) do
      _ = Library.broadcast_updated(scope, link_id)
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Accepts every pending suggestion of the link, oldest first, then finishes
  its triage (`finish_triage/2`). A suggestion that disappeared meanwhile is
  skipped.
  """
  @spec accept_all_suggestions(Scope.t(), Link.t()) ::
          {:ok, Link.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def accept_all_suggestions(%Scope{user: user} = scope, %Link{id: link_id} = link) do
    ids =
      Repo.all(
        from s in Suggestion,
          where: s.link_id == ^link_id and s.user_id == ^user.id and s.status == :pending,
          order_by: [asc: s.inserted_at, asc: s.id],
          select: s.id
      )

    ids
    |> Enum.reduce_while(:ok, fn id, :ok ->
      case accept_suggestion(scope, id) do
        {:ok, _collection} -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, _changeset} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> finish_triage(scope, link)
      error -> error
    end
  end

  @doc """
  Finishes the link's triage in one transaction: locks the link (as
  `replace_suggestions/3` does, so a concurrent enrichment cannot add
  suggestions), dismisses its remaining pending suggestions and takes it out
  of the inbox. Broadcasts the link after commit.
  """
  @spec finish_triage(Scope.t(), Link.t()) :: {:ok, Link.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def finish_triage(%Scope{user: user} = scope, %Link{id: link_id}) do
    fn ->
      case lock_link(user, link_id) do
        nil ->
          {:error, :not_found}

        %Link{} = link ->
          Repo.update_all(
            from(s in Suggestion, where: s.link_id == ^link.id and s.user_id == ^user.id and s.status == :pending),
            set: [status: :dismissed, updated_at: DateTime.utc_now(:second)]
          )

          link |> Ecto.Changeset.change(triaged_at: DateTime.utc_now(:second)) |> Repo.update()
      end
    end
    |> Repo.transact()
    |> case do
      {:ok, link} -> {:ok, Library.broadcast_link(scope, link)}
      {:error, _} = error -> error
    end
  end

  # Serializes the writers of a link's suggestions and triage. `NO KEY
  # UPDATE` still lets `accept_suggestion/2` add the link to a collection
  # (a foreign key check takes `KEY SHARE`), so the two cannot deadlock.
  defp lock_link(user, link_id) do
    Repo.one(from l in Link, where: l.id == ^link_id and l.user_id == ^user.id, lock: "FOR NO KEY UPDATE")
  end

  # Checks ownership against the database, not the (possibly stale) struct.
  defp owned(%Scope{user: user}, %Collection{id: id}) do
    case Repo.get_by(Collection, id: id, user_id: user.id) do
      %Collection{} = collection -> {:ok, collection}
      nil -> {:error, :not_found}
    end
  end

  # Checks ownership against the database, not the (possibly stale) struct.
  defp owned_collection?(user, collection) do
    Repo.exists?(from c in Collection, where: c.id == ^collection.id and c.user_id == ^user.id)
  end

  defp broadcast_collections_changed({:ok, _} = result, scope) do
    broadcast(scope, {:collections_changed})
    result
  end

  defp broadcast_collections_changed(result, _scope), do: result

  # A link deleted concurrently has nothing left to broadcast.
  defp broadcast_link_updated(scope, link) do
    _ = Library.broadcast_updated(scope, link.id)
    :ok
  end

  defp broadcast(%Scope{user: user}, message) do
    Phoenix.PubSub.broadcast(Acervo.PubSub, "links:#{user.id}", message)
  end
end
