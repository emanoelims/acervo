defmodule Acervo.Collections.SuggestionsTest do
  use Acervo.DataCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures

  alias Acervo.Collections
  alias Acervo.Collections.Collection
  alias Acervo.Collections.CollectionLink
  alias Acervo.Collections.Suggestion
  alias Acervo.Library.Link
  alias Acervo.Search.EmbedLink

  setup do
    scope = user_scope_fixture()
    Phoenix.PubSub.subscribe(Acervo.PubSub, "links:#{scope.user.id}")
    %{scope: scope, link: collection_link_fixture(scope)}
  end

  defp member?(collection_id, link_id) do
    Repo.exists?(from cl in CollectionLink, where: cl.collection_id == ^collection_id and cl.link_id == ^link_id)
  end

  defp statuses(link) do
    Repo.all(from s in Suggestion, where: s.link_id == ^link.id, order_by: s.inserted_at, select: s.status)
  end

  defp set_title(link, title) do
    link |> Ecto.Changeset.change(title: title) |> Repo.update!()
  end

  describe "accept_suggestion/2" do
    test "adds the link to an existing collection with source :suggestion", %{scope: scope, link: link} do
      collection = collection_fixture(scope)
      assert_receive {:collections_changed}
      suggestion = suggestion_fixture(scope, link, %{collection_id: collection.id})

      assert {:ok, %Collection{id: id}} = Collections.accept_suggestion(scope, suggestion.id)
      assert id == collection.id
      assert Repo.get_by!(CollectionLink, collection_id: collection.id, link_id: link.id).source == :suggestion
      assert Repo.get!(Suggestion, suggestion.id).status == :accepted

      assert_receive {:link_updated, %Link{suggestions: [], collections: [%Collection{}]}}
      refute_receive {:collections_changed}
    end

    test "enqueues the link's embedding when it joins the collection", %{scope: scope, link: link} do
      suggestion = suggestion_fixture(scope, link, %{proposed_name: "Receitas"})

      assert {:ok, _} = Collections.accept_suggestion(scope, suggestion.id)

      assert [%Oban.Job{state: "scheduled"}] = all_enqueued(worker: EmbedLink, args: %{"link_id" => link.id})
      assert %Link{embedding_status: :pending} = Repo.get!(Link, link.id)
    end

    test "enqueues nothing when the link already is a member, or for repointed links", %{scope: scope, link: link} do
      collection = collection_fixture(scope, %{name: "Receitas"})
      :ok = Collections.add_link(scope, collection, link)
      other = collection_link_fixture(scope)
      suggestion_fixture(scope, other, %{proposed_name: "Receitas"})
      suggestion = suggestion_fixture(scope, link, %{proposed_name: "Receitas"})
      Repo.delete_all(Oban.Job)

      assert {:ok, _} = Collections.accept_suggestion(scope, suggestion.id)
      assert all_enqueued(worker: EmbedLink) == []
    end

    test "accepting twice is not_found", %{scope: scope, link: link} do
      suggestion = suggestion_fixture(scope, link, %{collection_id: collection_fixture(scope).id})

      assert {:ok, _} = Collections.accept_suggestion(scope, suggestion.id)
      assert {:error, :not_found} = Collections.accept_suggestion(scope, suggestion.id)
    end

    test "a new name creates the collection and broadcasts", %{scope: scope, link: link} do
      suggestion = suggestion_fixture(scope, link, %{proposed_name: "Receitas de pão"})

      assert {:ok, %Collection{name: "Receitas de pão", slug: "receitas-de-pao"} = collection} =
               Collections.accept_suggestion(scope, suggestion.id)

      assert collection.user_id == scope.user.id
      assert member?(collection.id, link.id)
      assert_receive {:collections_changed}
      assert_receive {:link_updated, %Link{suggestions: []}}
    end

    test "a new name reuses a collection that differs only by case or accents", %{scope: scope, link: link} do
      existing = collection_fixture(scope, %{name: "Inspiração"})
      assert_receive {:collections_changed}
      suggestion = suggestion_fixture(scope, link, %{proposed_name: "inspiracao"})

      assert {:ok, %Collection{id: id}} = Collections.accept_suggestion(scope, suggestion.id)
      assert id == existing.id
      assert Repo.aggregate(from(c in Collection, where: c.user_id == ^scope.user.id), :count) == 1
      refute_receive {:collections_changed}
    end

    test "repoints other links' pending suggestions with the same name", %{scope: scope, link: link} do
      other = collection_link_fixture(scope)
      suggestion = suggestion_fixture(scope, link, %{proposed_name: "Receitas"})
      sibling = suggestion_fixture(scope, other, %{proposed_name: "receitas!"})

      assert {:ok, collection} = Collections.accept_suggestion(scope, suggestion.id)

      assert %Suggestion{status: :pending, collection_id: collection_id} = Repo.get!(Suggestion, sibling.id)
      assert collection_id == collection.id
      refute member?(collection.id, other.id)

      other_id = other.id
      assert_receive {:link_updated, %Link{id: ^other_id, suggestions: [%{collection: %Collection{}}]}}
    end

    test "deletes a repointed duplicate when that link already has the collection pending or as a member",
         %{scope: scope, link: link} do
      collection = collection_fixture(scope, %{name: "Receitas"})
      pending_link = collection_link_fixture(scope)
      member_link = collection_link_fixture(scope)
      :ok = Collections.add_link(scope, collection, member_link)

      # Created before the collection existed, so they still carry only the name.
      suggestion = suggestion_fixture(scope, link, %{proposed_name: "Receitas"})
      already_pending = suggestion_fixture(scope, pending_link, %{collection_id: collection.id})
      duplicate = suggestion_fixture(scope, pending_link, %{proposed_name: "Receitas"})
      member_duplicate = suggestion_fixture(scope, member_link, %{proposed_name: "receitas"})

      assert {:ok, _} = Collections.accept_suggestion(scope, suggestion.id)

      refute Repo.get(Suggestion, duplicate.id)
      refute Repo.get(Suggestion, member_duplicate.id)
      assert Repo.get!(Suggestion, already_pending.id).status == :pending
    end

    test "a suggestion whose collection was deleted cascades away", %{scope: scope, link: link} do
      collection = collection_fixture(scope)
      suggestion = suggestion_fixture(scope, link, %{collection_id: collection.id})
      {:ok, _} = Collections.delete_collection(scope, collection)

      refute Repo.get(Suggestion, suggestion.id)
      assert {:error, :not_found} = Collections.accept_suggestion(scope, suggestion.id)
    end

    test "an unknown id is not_found", %{scope: scope} do
      assert {:error, :not_found} = Collections.accept_suggestion(scope, Ecto.UUID.generate())
    end
  end

  describe "dismiss_suggestion/2" do
    test "marks it dismissed and broadcasts the link", %{scope: scope, link: link} do
      suggestion = suggestion_fixture(scope, link, %{proposed_name: "Receitas"})

      assert :ok = Collections.dismiss_suggestion(scope, suggestion.id)
      assert Repo.get!(Suggestion, suggestion.id).status == :dismissed
      assert_receive {:link_updated, %Link{suggestions: []}}
      assert {:error, :not_found} = Collections.dismiss_suggestion(scope, suggestion.id)
    end
  end

  describe "accept_all_suggestions/2 and finish_triage/2" do
    test "accept_all accepts every pending suggestion and triages", %{scope: scope, link: link} do
      collection = collection_fixture(scope)
      suggestion_fixture(scope, link, %{collection_id: collection.id})
      suggestion_fixture(scope, link, %{proposed_name: "Novidades"})

      assert {:ok, %Link{triaged_at: %DateTime{}, suggestions: []} = triaged} =
               Collections.accept_all_suggestions(scope, link)

      assert triaged.collections |> Enum.map(& &1.name) |> Enum.sort() == Enum.sort([collection.name, "Novidades"])
      assert statuses(link) == [:accepted, :accepted]
    end

    test "finish_triage dismisses the rest and triages", %{scope: scope, link: link} do
      suggestion_fixture(scope, link, %{proposed_name: "Receitas"})
      suggestion_fixture(scope, link, %{proposed_name: "Pães"})

      assert {:ok, %Link{triaged_at: %DateTime{}, suggestions: []}} = Collections.finish_triage(scope, link)
      assert statuses(link) == [:dismissed, :dismissed]
      assert_receive {:link_updated, %Link{triaged_at: %DateTime{}}}
    end

    test "after finish_triage the link has no pending suggestions and gets no new ones",
         %{scope: scope, link: link} do
      collection = collection_fixture(scope)
      suggestion_fixture(scope, link, %{proposed_name: "Receitas"})

      assert {:ok, _} = Collections.finish_triage(scope, link)
      refute :pending in statuses(link)

      assert {:ok, []} =
               Collections.replace_suggestions(scope, link, [
                 %{collection_id: collection.id, reason: "r"},
                 %{proposed_name: "Nova", reason: "r"}
               ])

      refute :pending in statuses(link)
    end

    test "finish_triage on a deleted link is not found", %{scope: scope, link: link} do
      Repo.delete!(link)
      assert {:error, :not_found} = Collections.finish_triage(scope, link)
      refute_receive {:link_updated, _}
    end
  end

  describe "isolation" do
    test "another user cannot accept or dismiss a suggestion", %{scope: scope, link: link} do
      suggestion = suggestion_fixture(scope, link, %{proposed_name: "Receitas"})
      intruder = user_scope_fixture()

      assert {:error, :not_found} = Collections.accept_suggestion(intruder, suggestion.id)
      assert {:error, :not_found} = Collections.dismiss_suggestion(intruder, suggestion.id)
      assert {:error, :not_found} = Collections.accept_all_suggestions(intruder, link)
      assert {:error, :not_found} = Collections.finish_triage(intruder, link)
      assert {:error, :not_found} = Collections.replace_suggestions(intruder, link, [%{proposed_name: "X", reason: "r"}])
      assert Repo.get!(Suggestion, suggestion.id).status == :pending
      refute Repo.get!(Link, link.id).triaged_at
    end

    test "repointing never touches another user's suggestions with the same name", %{scope: scope, link: link} do
      other_scope = user_scope_fixture()
      other_link = collection_link_fixture(other_scope)
      theirs = suggestion_fixture(other_scope, other_link, %{proposed_name: "Receitas"})
      suggestion = suggestion_fixture(scope, link, %{proposed_name: "Receitas"})

      assert {:ok, _} = Collections.accept_suggestion(scope, suggestion.id)
      assert %Suggestion{collection_id: nil, status: :pending} = Repo.get!(Suggestion, theirs.id)
    end
  end

  describe "replace_suggestions/3" do
    test "replaces pending suggestions and keeps decided ones", %{scope: scope, link: link} do
      old = suggestion_fixture(scope, link, %{proposed_name: "Velha"})
      accepted = suggestion_fixture(scope, link, %{proposed_name: "Aceita", status: :accepted})
      dismissed = suggestion_fixture(scope, link, %{proposed_name: "Recusada", status: :dismissed})
      collection = collection_fixture(scope)

      assert {:ok, [first, second]} =
               Collections.replace_suggestions(scope, link, [
                 %{collection_id: collection.id, reason: "Fits"},
                 %{proposed_name: "Nova", reason: "New"}
               ])

      assert first.collection_id == collection.id
      assert second.proposed_name == "Nova"
      refute Repo.get(Suggestion, old.id)
      assert Repo.get(Suggestion, accepted.id)
      assert Repo.get(Suggestion, dismissed.id)
    end

    test "drops another user's collection, memberships, dismissed targets and duplicates, and keeps 3",
         %{scope: scope, link: link} do
      theirs = collection_fixture(user_scope_fixture())
      member = collection_fixture(scope)
      dismissed = collection_fixture(scope)
      a = collection_fixture(scope)
      b = collection_fixture(scope)
      :ok = Collections.add_link(scope, member, link)
      suggestion_fixture(scope, link, %{collection_id: dismissed.id, status: :dismissed})
      suggestion_fixture(scope, link, %{proposed_name: "Recusada", status: :dismissed})

      assert {:ok, suggestions} =
               Collections.replace_suggestions(scope, link, [
                 %{collection_id: theirs.id, reason: "injected"},
                 %{collection_id: member.id, reason: "already in"},
                 %{collection_id: dismissed.id, reason: "dismissed"},
                 %{proposed_name: "recusada", reason: "dismissed name"},
                 %{collection_id: a.id, reason: "one"},
                 %{collection_id: a.id, reason: "dup"},
                 %{proposed_name: "Nova", reason: "two"},
                 %{proposed_name: "NOVA", reason: "dup name"},
                 %{collection_id: b.id, reason: "three"},
                 %{proposed_name: "Quarta", reason: "four"}
               ])

      assert Enum.map(suggestions, &(&1.collection_id || &1.proposed_name)) == [a.id, "Nova", b.id]
      assert Enum.map(suggestions, & &1.reason) == ["one", "two", "three"]
    end

    test "a proposed name matching an existing collection becomes that collection", %{scope: scope, link: link} do
      collection = collection_fixture(scope, %{name: "Inspiração"})

      assert {:ok, [suggestion]} =
               Collections.replace_suggestions(scope, link, [%{proposed_name: "inspiracao", reason: "r"}])

      assert suggestion.collection_id == collection.id
      assert suggestion.proposed_name == nil
    end

    test "never re-suggests the collection of a dismissed name", %{scope: scope, link: link} do
      collection = collection_fixture(scope, %{name: "Receitas"})
      suggestion_fixture(scope, link, %{proposed_name: "Receitas", status: :dismissed})

      assert {:ok, []} = Collections.replace_suggestions(scope, link, [%{collection_id: collection.id, reason: "r"}])
    end

    test "broadcasts nothing", %{scope: scope, link: link} do
      assert {:ok, [_]} = Collections.replace_suggestions(scope, link, [%{proposed_name: "Nova", reason: "r"}])
      refute_receive {:link_updated, _}
    end
  end

  describe "list_for_enrichment/1" do
    test "lists up to 50 collections with the 3 newest link titles each", %{scope: scope} do
      first = collection_fixture(scope, %{name: "Aaa", description: "Primeira", position: 0})
      for i <- 1..50, do: collection_fixture(scope, %{name: "Z#{i}", position: 1})

      for i <- 1..4 do
        link = scope |> collection_link_fixture() |> set_title("Título #{i} " <> String.duplicate("x", 200))

        Repo.update_all(from(l in Link, where: l.id == ^link.id),
          set: [inserted_at: DateTime.shift(~U[2026-01-01 00:00:00Z], day: i)]
        )

        :ok = Collections.add_link(scope, first, link)
      end

      untitled = collection_link_fixture(scope)
      :ok = Collections.add_link(scope, first, untitled)

      list = Collections.list_for_enrichment(scope)
      assert length(list) == 50

      assert [%{id: id, slug: "aaa", name: "Aaa", description: "Primeira", examples: examples} | _] = list
      assert id == first.id
      assert Enum.map(examples, &String.slice(&1, 0, 8)) == ["Título 4", "Título 3", "Título 2"]
      assert Enum.all?(examples, &(String.length(&1) == 120))
      assert Enum.at(list, 1).examples == []
    end

    test "only lists the scope's collections", %{scope: scope} do
      collection_fixture(user_scope_fixture())
      assert Collections.list_for_enrichment(scope) == []
    end
  end
end
