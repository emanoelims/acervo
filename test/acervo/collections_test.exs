defmodule Acervo.CollectionsTest do
  use Acervo.DataCase, async: true

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures

  alias Acervo.Collections
  alias Acervo.Collections.Collection
  alias Acervo.Collections.CollectionLink
  alias Acervo.Library.Link

  setup do
    scope = user_scope_fixture()
    Phoenix.PubSub.subscribe(Acervo.PubSub, "links:#{scope.user.id}")
    %{scope: scope}
  end

  describe "create/update/delete" do
    test "creates with a derived slug and broadcasts", %{scope: scope} do
      assert {:ok, %Collection{} = c} = Collections.create_collection(scope, %{name: "Café Ideas"})
      assert c.slug == "cafe-ideas"
      assert c.user_id == scope.user.id
      assert_receive {:collections_changed}
    end

    test "requires a name", %{scope: scope} do
      assert {:error, changeset} = Collections.create_collection(scope, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "duplicate slugs error on name, including equivalent names", %{scope: scope} do
      collection_fixture(scope, %{name: "Read Later"})
      assert {:error, changeset} = Collections.create_collection(scope, %{name: "read   later!"})
      assert %{name: [_]} = errors_on(changeset)
    end

    test "same name is allowed for different users", %{scope: scope} do
      collection_fixture(scope, %{name: "Shared"})
      assert {:ok, _} = Collections.create_collection(user_scope_fixture(), %{name: "Shared"})
    end

    test "updates", %{scope: scope} do
      c = collection_fixture(scope)
      assert {:ok, c} = Collections.update_collection(scope, c, %{name: "Renamed", description: "d"})
      assert c.slug == "renamed"
      assert Collections.get_collection_by_slug!(scope, "renamed").id == c.id
    end

    test "update rejects another user's collection", %{scope: scope} do
      c = collection_fixture(scope)
      assert {:error, :not_found} = Collections.update_collection(user_scope_fixture(), c, %{name: "x"})
    end

    test "delete keeps the links", %{scope: scope} do
      c = collection_fixture(scope)
      link = collection_link_fixture(scope)
      :ok = Collections.add_link(scope, c, link)

      assert {:ok, _} = Collections.delete_collection(scope, c)
      assert Repo.get(Link, link.id)
      assert Repo.aggregate(CollectionLink, :count) == 0
      assert_receive {:collections_changed}
    end

    test "delete rejects another user's collection", %{scope: scope} do
      c = collection_fixture(scope)
      assert {:error, :not_found} = Collections.delete_collection(user_scope_fixture(), c)
      assert Repo.get(Collection, c.id)
    end

    test "get_collection_by_slug! is user scoped", %{scope: scope} do
      c = collection_fixture(scope, %{name: "Mine"})
      assert Collections.get_collection_by_slug!(scope, "mine").id == c.id

      assert_raise Ecto.NoResultsError, fn ->
        Collections.get_collection_by_slug!(user_scope_fixture(), "mine")
      end
    end

    test "change_collection returns a changeset", %{scope: scope} do
      c = collection_fixture(scope)
      assert %Ecto.Changeset{} = Collections.change_collection(c, %{name: "x"})
    end
  end

  describe "membership" do
    test "add_link is idempotent", %{scope: scope} do
      c = collection_fixture(scope)
      link = collection_link_fixture(scope)
      assert :ok = Collections.add_link(scope, c, link)
      assert :ok = Collections.add_link(scope, c, link)
      assert Repo.aggregate(CollectionLink, :count) == 1
      link_id = link.id
      c_id = c.id
      assert_receive {:link_updated, %Link{id: ^link_id, collections: [%{id: ^c_id}], images: []}}
    end

    test "remove_link", %{scope: scope} do
      c = collection_fixture(scope)
      link = collection_link_fixture(scope)
      :ok = Collections.add_link(scope, c, link)
      link_id = link.id
      assert_receive {:link_updated, %Link{id: ^link_id, collections: [_]}}

      assert :ok = Collections.remove_link(scope, c, link)
      assert Repo.aggregate(CollectionLink, :count) == 0
      assert_receive {:link_updated, %Link{id: ^link_id, collections: [], images: []}}
      assert :ok = Collections.remove_link(scope, c, link)
    end

    test "cannot cross users", %{scope: scope} do
      other = user_scope_fixture()
      mine = collection_fixture(scope)
      theirs = collection_fixture(other)
      my_link = collection_link_fixture(scope)
      their_link = collection_link_fixture(other)

      assert {:error, :not_found} = Collections.add_link(other, theirs, my_link)
      assert {:error, :not_found} = Collections.add_link(other, mine, their_link)
      assert {:error, :not_found} = Collections.add_link(scope, theirs, my_link)
      assert {:error, :not_found} = Collections.remove_link(other, mine, my_link)
      assert Repo.aggregate(CollectionLink, :count) == 0
    end
  end

  describe "list_collections/1" do
    test "orders by position then name, scoped to the user", %{scope: scope} do
      b = collection_fixture(scope, %{name: "B", position: 1})
      a = collection_fixture(scope, %{name: "A", position: 1})
      z = collection_fixture(scope, %{name: "Z", position: 0})
      collection_fixture(user_scope_fixture())

      assert Enum.map(Collections.list_collections(scope), & &1.id) == [z.id, a.id, b.id]
    end

    test "counts links", %{scope: scope} do
      c = collection_fixture(scope, %{name: "Full", position: 0})
      empty = collection_fixture(scope, %{name: "Empty", position: 1})

      links = for _ <- 1..7, do: collection_link_fixture(scope)
      Enum.each(links, &Collections.add_link(scope, c, &1))

      [full, empty_listed] = Collections.list_collections(scope)

      assert full.id == c.id
      assert full.link_count == 7
      assert empty_listed.id == empty.id
      assert empty_listed.link_count == 0
    end

    test "counts do not leak across users", %{scope: scope} do
      other = user_scope_fixture()
      c = collection_fixture(scope)
      link = collection_link_fixture(scope)
      :ok = Collections.add_link(scope, c, link)

      assert [%{link_count: 0}] =
               other |> tap(&collection_fixture/1) |> Collections.list_collections()
    end
  end
end
