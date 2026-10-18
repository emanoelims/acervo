defmodule Acervo.Collections do
  @moduledoc """
  Manual collections and link membership, isolated per user.

  Mutations broadcast on the `"links:<user_id>"` topic of `Acervo.PubSub`:
  `{:collections_changed}` when collections change and `{:link_updated, link}`,
  with the link's images and collections preloaded, when a link's membership
  changes.
  """

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.Collections.Collection
  alias Acervo.Collections.CollectionLink
  alias Acervo.Library
  alias Acervo.Library.Link
  alias Acervo.Repo

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
      |> Repo.update()
      |> broadcast_collections_changed(scope)
    end
  end

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
      |> Repo.delete()
      |> broadcast_collections_changed(scope)
    end
  end

  @doc """
  Adds a link to a collection. Idempotent. Returns `{:error, :not_found}` when
  either record does not belong to the scope's user.
  """
  def add_link(%Scope{} = scope, %Collection{} = collection, %Link{} = link) do
    with :ok <- authorize(scope, collection, link) do
      Repo.insert!(%CollectionLink{collection_id: collection.id, link_id: link.id, source: :manual},
        on_conflict: :nothing,
        conflict_target: [:collection_id, :link_id]
      )

      broadcast_link_updated(scope, link)
    end
  end

  @doc """
  Removes a link from a collection. Idempotent. Returns `{:error, :not_found}`
  when either record does not belong to the scope's user.
  """
  def remove_link(%Scope{} = scope, %Collection{} = collection, %Link{} = link) do
    with :ok <- authorize(scope, collection, link) do
      Repo.delete_all(from cl in CollectionLink, where: cl.collection_id == ^collection.id and cl.link_id == ^link.id)

      broadcast_link_updated(scope, link)
    end
  end

  # Checks ownership against the database, not the (possibly stale) struct.
  defp owned(%Scope{user: user}, %Collection{id: id}) do
    case Repo.get_by(Collection, id: id, user_id: user.id) do
      %Collection{} = collection -> {:ok, collection}
      nil -> {:error, :not_found}
    end
  end

  # Checks ownership against the database, not the (possibly stale) structs.
  defp authorize(%Scope{user: user}, collection, link) do
    owned_collection? = Repo.exists?(from c in Collection, where: c.id == ^collection.id and c.user_id == ^user.id)
    owned_link? = Repo.exists?(from l in Link, where: l.id == ^link.id and l.user_id == ^user.id)

    if owned_collection? and owned_link?, do: :ok, else: {:error, :not_found}
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
