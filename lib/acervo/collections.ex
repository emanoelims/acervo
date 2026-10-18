defmodule Acervo.Collections do
  @moduledoc """
  Manual collections and link membership, isolated per user.

  Mutations broadcast on the `"links:<user_id>"` topic of `Acervo.PubSub`:
  `{:collections_changed}` when collections change and `{:link_updated, link}`
  when a link's membership changes.
  """

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.Collections.Collection
  alias Acervo.Collections.CollectionLink
  alias Acervo.Library.Link
  alias Acervo.Repo

  @cover_limit 4

  @doc """
  Lists the user's collections ordered by position then name. Each one carries
  a virtual `link_count` and `cover_image_ids` (up to #{@cover_limit} ids of the
  position 0 images of the most recent member links), computed in one query.
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
            ),
          cover_image_ids:
            type(
              fragment(
                """
                ARRAY(
                  SELECT li.id FROM collection_links cl
                  JOIN links l ON l.id = cl.link_id
                  JOIN link_images li ON li.link_id = l.id AND li.position = 0
                  WHERE cl.collection_id = ?
                  ORDER BY l.inserted_at DESC, l.id DESC
                  LIMIT ?
                )
                """,
                c.id,
                ^@cover_limit
              ),
              {:array, Ecto.UUID}
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

  def update_collection(%Scope{user: user} = scope, %Collection{user_id: user_id} = collection, attrs)
      when user.id == user_id do
    collection
    |> Collection.changeset(attrs)
    |> Repo.update()
    |> broadcast_collections_changed(scope)
  end

  def update_collection(%Scope{}, %Collection{}, _attrs), do: {:error, :not_found}

  def delete_collection(%Scope{user: user} = scope, %Collection{user_id: user_id} = collection) when user.id == user_id do
    collection
    |> Repo.delete()
    |> broadcast_collections_changed(scope)
  end

  def delete_collection(%Scope{}, %Collection{}), do: {:error, :not_found}

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

  defp broadcast_link_updated(scope, link) do
    broadcast(scope, {:link_updated, link})
    :ok
  end

  defp broadcast(%Scope{user: user}, message) do
    Phoenix.PubSub.broadcast(Acervo.PubSub, "links:#{user.id}", message)
  end
end
