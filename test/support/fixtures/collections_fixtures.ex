defmodule Acervo.CollectionsFixtures do
  @moduledoc """
  Test helpers for `Acervo.Collections`. Links and images are inserted
  directly so these fixtures do not depend on the Library context.
  """

  alias Acervo.Collections
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage
  alias Acervo.Repo

  def unique_collection_name, do: "Collection #{System.unique_integer([:positive])}"

  def collection_fixture(scope, attrs \\ %{}) do
    {:ok, collection} =
      attrs
      |> Enum.into(%{name: unique_collection_name()})
      |> then(&Collections.create_collection(scope, &1))

    collection
  end

  def collection_link_fixture(scope, attrs \\ %{}) do
    url = "https://example.com/#{System.unique_integer([:positive])}"
    attrs = Enum.into(attrs, %{url: url, canonical_url: url, source: :generic})

    %Link{user_id: scope.user.id}
    |> Link.create_changeset(attrs)
    |> Repo.insert!()
  end

  def collection_link_image_fixture(link, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        position: 0,
        kind: :preview,
        content_type: "image/webp",
        bytes: <<1, 2, 3>>,
        width: 1,
        height: 1,
        sha256: String.duplicate("a", 64)
      })

    %LinkImage{link_id: link.id}
    |> LinkImage.changeset(attrs)
    |> Repo.insert!()
  end
end
