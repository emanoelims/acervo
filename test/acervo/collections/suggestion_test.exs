defmodule Acervo.Collections.SuggestionTest do
  use Acervo.DataCase, async: true

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures

  alias Acervo.Collections.Suggestion

  setup do
    scope = user_scope_fixture()
    %{scope: scope, link: collection_link_fixture(scope), collection: collection_fixture(scope)}
  end

  defp insert(scope, link, attrs, status \\ :pending) do
    %Suggestion{user_id: scope.user.id, link_id: link.id, status: status}
    |> Suggestion.changeset(attrs)
    |> Repo.insert()
  end

  describe "changeset/2" do
    test "derives the normalized name from the proposed name" do
      changeset = Suggestion.changeset(%Suggestion{}, %{proposed_name: "  Inspiração de UI ", reason: "Interfaces"})

      assert changeset.valid?
      assert changeset.changes.proposed_name == "Inspiração de UI"
      assert changeset.changes.normalized_name == "inspiracao-de-ui"
    end

    test "strips NUL bytes from the name and reason" do
      changeset = Suggestion.changeset(%Suggestion{}, %{proposed_name: "Re" <> <<0>> <> "ceitas", reason: "pão" <> <<0>>})

      assert changeset.changes.proposed_name == "Receitas"
      assert changeset.changes.reason == "pão"
    end

    test "limits the name to 80 and the reason to 140 characters" do
      errors =
        errors_on(
          Suggestion.changeset(%Suggestion{}, %{
            proposed_name: String.duplicate("a", 81),
            reason: String.duplicate("r", 141)
          })
        )

      assert [_] = errors.proposed_name
      assert [_] = errors.reason
    end

    test "needs a collection or a name with letters or numbers" do
      assert %{collection_id: [_]} = errors_on(Suggestion.changeset(%Suggestion{}, %{reason: "why"}))
      assert %{collection_id: [_]} = errors_on(Suggestion.changeset(%Suggestion{}, %{proposed_name: " ?! "}))
      assert Suggestion.changeset(%Suggestion{}, %{collection_id: Ecto.UUID.generate()}).valid?
    end

    test "defaults the status to pending" do
      assert %Suggestion{status: :pending} = %Suggestion{}
    end
  end

  describe "database constraints" do
    test "the check constraint rejects a suggestion without a target", %{scope: scope, link: link} do
      assert {:error, changeset} =
               %Suggestion{user_id: scope.user.id, link_id: link.id, reason: "why"}
               |> Ecto.Changeset.change()
               |> Ecto.Changeset.check_constraint(:collection_id, name: :target)
               |> Repo.insert()

      assert %{collection_id: ["is invalid"]} = errors_on(changeset)
    end

    test "only one pending suggestion per link and collection", %{scope: scope, link: link, collection: collection} do
      assert {:ok, _} = insert(scope, link, %{collection_id: collection.id})
      assert {:error, changeset} = insert(scope, link, %{collection_id: collection.id})
      assert %{collection_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "a dismissed suggestion does not block a pending one", %{scope: scope, link: link, collection: collection} do
      assert {:ok, _} = insert(scope, link, %{collection_id: collection.id}, :dismissed)
      assert {:ok, _} = insert(scope, link, %{collection_id: collection.id})
      assert {:ok, _} = insert(scope, link, %{proposed_name: "Receitas"}, :dismissed)
      assert {:ok, _} = insert(scope, link, %{proposed_name: "receitas"})
    end

    test "only one pending suggestion per link and new name", %{scope: scope, link: link} do
      assert {:ok, _} = insert(scope, link, %{proposed_name: "Receitas"})
      assert {:error, changeset} = insert(scope, link, %{proposed_name: "RECEITAS!"})
      assert %{normalized_name: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, _} = insert(scope, collection_link_fixture(scope), %{proposed_name: "Receitas"})
    end

    test "deleting the link or the collection deletes its suggestions",
         %{scope: scope, link: link, collection: collection} do
      {:ok, by_collection} = insert(scope, link, %{collection_id: collection.id})
      {:ok, by_name} = insert(scope, link, %{proposed_name: "Receitas"})

      Repo.delete!(collection)
      refute Repo.get(Suggestion, by_collection.id)
      assert Repo.get(Suggestion, by_name.id)

      Repo.delete!(link)
      refute Repo.get(Suggestion, by_name.id)
    end
  end
end
