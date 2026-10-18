defmodule Acervo.Storage.Database do
  @moduledoc "Stores image bytes in the `link_images` table."
  @behaviour Acervo.Storage

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage
  alias Acervo.Repo

  @impl true
  def put(%Scope{user: user}, %Link{id: link_id}, attrs) do
    link = Repo.get_by!(Link, id: link_id, user_id: user.id)

    %LinkImage{link_id: link.id}
    |> LinkImage.changeset(attrs)
    |> Repo.insert()
  end

  @impl true
  def fetch(%Scope{user: user}, id) do
    query =
      from i in LinkImage,
        join: l in assoc(i, :link),
        where: i.id == ^id and l.user_id == ^user.id

    case Repo.one(query) do
      nil -> :error
      image -> {:ok, image}
    end
  end
end
