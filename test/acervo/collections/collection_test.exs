defmodule Acervo.Collections.CollectionTest do
  use Acervo.DataCase, async: true

  import Acervo.AccountsFixtures

  alias Acervo.Collections.Collection
  alias Acervo.Collections.CollectionLink
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage

  describe "changeset/2" do
    test "derives the slug from the name" do
      changeset = Collection.changeset(%Collection{}, %{name: "Inspiração de UI"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :slug) == "inspiracao-de-ui"
    end

    test "collapses runs of symbols and trims dashes" do
      changeset = Collection.changeset(%Collection{}, %{name: "  --Café & Cia!!  "})
      assert Ecto.Changeset.get_change(changeset, :slug) == "cafe-cia"
    end

    test "re-derives the slug on rename" do
      {:ok, collection} =
        %Collection{user_id: user_fixture().id} |> Collection.changeset(%{name: "Um"}) |> Repo.insert()

      assert collection.slug == "um"

      changeset = Collection.changeset(collection, %{name: "Dois Três"})
      assert Ecto.Changeset.get_change(changeset, :slug) == "dois-tres"
    end

    test "requires a name" do
      assert %{name: ["can't be blank"]} = errors_on(Collection.changeset(%Collection{}, %{}))
    end

    test "errors when the name has no alphanumeric characters" do
      changeset = Collection.changeset(%Collection{}, %{name: "!!! ???"})
      assert %{name: [_]} = errors_on(changeset)
    end

    test "limits name to 80 and description to 280 characters" do
      changeset =
        Collection.changeset(%Collection{}, %{name: String.duplicate("a", 81), description: String.duplicate("a", 281)})

      errors = errors_on(changeset)
      assert [_] = errors.name
      assert [_] = errors.description
    end

    test "defaults position to 0" do
      assert %Collection{position: 0} = %Collection{}
    end

    test "reports a slug clash for the same user" do
      user = user_fixture()
      assert {:ok, _} = %Collection{user_id: user.id} |> Collection.changeset(%{name: "Design"}) |> Repo.insert()

      assert {:error, changeset} =
               %Collection{user_id: user.id} |> Collection.changeset(%{name: "design!"}) |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "associations" do
    test "joins links and collections, and orders images by position" do
      user = user_fixture()

      {:ok, link} =
        %Link{user_id: user.id}
        |> Link.create_changeset(%{url: "https://a.test", canonical_url: "https://a.test", source: :generic})
        |> Repo.insert()

      {:ok, collection} = %Collection{user_id: user.id} |> Collection.changeset(%{name: "Design"}) |> Repo.insert()

      assert {:ok, %CollectionLink{source: :manual}} =
               Repo.insert(%CollectionLink{collection_id: collection.id, link_id: link.id})

      assert {:error, _} =
               %CollectionLink{collection_id: collection.id, link_id: link.id}
               |> Ecto.Changeset.change()
               |> Ecto.Changeset.unique_constraint([:collection_id, :link_id])
               |> Repo.insert()

      for position <- [2, 1] do
        Repo.insert!(%LinkImage{
          link_id: link.id,
          position: position,
          kind: :preview,
          content_type: "image/webp",
          bytes: <<1>>
        })
      end

      link = Repo.preload(link, [:collections, :images])
      assert [%{id: id}] = link.collections
      assert id == collection.id
      assert [1, 2] = Enum.map(link.images, & &1.position)
    end
  end
end
