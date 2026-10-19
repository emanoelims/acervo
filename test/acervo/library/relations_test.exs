defmodule Acervo.Library.RelationsTest do
  use Acervo.DataCase, async: true

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.Library
  alias Acervo.Library.LinkRelation

  setup do
    scope = user_scope_fixture()
    Library.subscribe(scope)
    %{scope: scope, a: link_fixture(scope), b: link_fixture(scope), c: link_fixture(scope)}
  end

  defp ids(links), do: Enum.map(links, & &1.id)

  test "relate/3 is symmetric and stores one ordered row", %{scope: scope, a: a, b: b} do
    assert {:ok, %LinkRelation{link_a_id: first, link_b_id: second}} = Library.relate(scope, b, a)
    assert first < second
    assert Enum.sort([first, second]) == Enum.sort([a.id, b.id])

    assert ids(Library.list_related(scope, a)) == [b.id]
    assert ids(Library.list_related(scope, b)) == [a.id]

    assert_receive {:relations_changed, [_, _] = changed}
    assert Enum.sort(changed) == Enum.sort([a.id, b.id])
  end

  test "lists the most recently related first", %{scope: scope, a: a, b: b, c: c} do
    {:ok, _} = Library.relate(scope, a, b)
    {:ok, relation} = Library.relate(scope, a, c)
    Repo.update_all(from(r in LinkRelation, where: r.id == ^relation.id), set: [inserted_at: ~U[2099-01-01 00:00:00Z]])

    assert ids(Library.list_related(scope, a)) == [c.id, b.id]
  end

  test "rejects the link itself and a pair already related, in either order", %{scope: scope, a: a, b: b} do
    assert {:error, :self} = Library.relate(scope, a, a)
    assert {:ok, _} = Library.relate(scope, a, b)
    assert {:error, :duplicate} = Library.relate(scope, a, b)
    assert {:error, :duplicate} = Library.relate(scope, b, a)
    assert Repo.aggregate(LinkRelation, :count) == 1
  end

  test "never relates another user's link", %{scope: scope, a: a} do
    other = user_scope_fixture()
    theirs = link_fixture(other)

    assert {:error, :not_found} = Library.relate(scope, a, theirs)
    assert {:error, :not_found} = Library.relate(other, theirs, a.id)
    assert {:error, :not_found} = Library.relate(scope, a, "not-a-uuid")
    assert Repo.aggregate(LinkRelation, :count) == 0
  end

  test "another user sees and removes nothing", %{scope: scope, a: a, b: b} do
    {:ok, _} = Library.relate(scope, a, b)
    other = user_scope_fixture()

    assert Library.list_related(other, a) == []
    assert :ok = Library.unrelate(other, a, b)
    assert ids(Library.list_related(scope, a)) == [b.id]
  end

  test "unrelate/3 removes the pair from both sides and is idempotent", %{scope: scope, a: a, b: b} do
    {:ok, _} = Library.relate(scope, a, b)
    assert_receive {:relations_changed, _}

    assert :ok = Library.unrelate(scope, b, a.id)
    assert Library.list_related(scope, a) == []
    assert Library.list_related(scope, b) == []
    assert_receive {:relations_changed, _}

    assert :ok = Library.unrelate(scope, a, b)
    refute_receive {:relations_changed, _}
  end

  test "deleting a link deletes its relations", %{scope: scope, a: a, b: b} do
    {:ok, _} = Library.relate(scope, a, b)
    {:ok, _} = Library.delete_link(scope, b)

    assert Library.list_related(scope, a) == []
    assert Repo.aggregate(LinkRelation, :count) == 0
  end
end
