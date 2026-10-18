defmodule AcervoWeb.InboxTriageTest do
  use AcervoWeb.ConnCase, async: true

  import Acervo.CollectionsFixtures
  import Acervo.LibraryFixtures
  import Phoenix.LiveViewTest

  alias Acervo.Collections
  alias Acervo.Collections.Suggestion
  alias Acervo.Library
  alias Acervo.Library.Link
  alias Acervo.Repo

  setup :register_and_log_in_user

  defp ready(link, attrs \\ %{}) do
    link
    |> Link.capture_changeset(%{status: :ready, title: "A post"})
    |> Repo.update!()
    |> Link.enrichment_changeset(Enum.into(attrs, %{enrichment_status: :ready}))
    |> Repo.update!()
  end

  defp status(suggestion), do: Repo.get!(Suggestion, suggestion.id).status
  defp collection_names(scope, link), do: Enum.map(Library.get_link!(scope, link.id).collections, & &1.name)

  describe "inbox cards" do
    test "show pending suggestions as chips, never decided ones", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> ready()
      existing = collection_fixture(scope, %{name: "Receitas"})
      pending = suggestion_fixture(scope, link, %{collection_id: existing.id, reason: "Uma receita"})
      new_name = suggestion_fixture(scope, link, %{proposed_name: "Pães"})
      dismissed = suggestion_fixture(scope, link, %{proposed_name: "Bolos", status: :dismissed})

      {:ok, view, _html} = live(conn, ~p"/inbox")

      assert has_element?(view, "#link-#{link.id} #card-#{link.id}")
      assert has_element?(view, "#suggestion-#{pending.id}[title='Uma receita'] .lucide-sparkle")
      assert has_element?(view, "#suggestion-#{pending.id}[aria-label='Add to Receitas']", "Receitas")
      assert has_element?(view, "#suggestion-#{new_name.id} .lucide-plus")
      assert has_element?(view, "#suggestion-#{new_name.id}", "Pães")
      refute has_element?(view, "#suggestion-#{dismissed.id}")
      assert has_element?(view, "#accept-all-#{link.id}")
      assert has_element?(view, "#done-#{link.id}")
    end

    test "show at most three chips, suggestions first", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> ready()

      for name <- ~w(Um Dois) do
        collection = collection_fixture(scope, %{name: name})
        :ok = Collections.add_link(scope, collection, link)
      end

      a = suggestion_fixture(scope, link, %{proposed_name: "Três"})
      b = suggestion_fixture(scope, link, %{proposed_name: "Quatro"})

      {:ok, view, _html} = live(conn, ~p"/inbox")

      assert has_element?(view, "#suggestion-#{a.id}")
      assert has_element?(view, "#suggestion-#{b.id}")

      assert view
             |> element("#link-#{link.id} .ibar-chips")
             |> render()
             |> then(&Regex.scan(~r/class="chip /, &1))
             |> length() == 3
    end

    test "accept all appears only with two or more suggestions", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> ready()
      suggestion_fixture(scope, link, %{proposed_name: "Só uma"})

      {:ok, view, _html} = live(conn, ~p"/inbox")

      refute has_element?(view, "#accept-all-#{link.id}")
      assert has_element?(view, "#done-#{link.id}")
    end

    test "a quiet placeholder holds the row while enrichment runs", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> ready(enrichment_status: :pending)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      assert has_element?(view, "#link-#{link.id} .chip.is-waiting[aria-hidden=true]")
      assert has_element?(view, "#done-#{link.id}")
    end

    test "a failed enrichment shows no chips and can still be finished", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> ready(enrichment_status: :failed)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      refute has_element?(view, "#link-#{link.id} .chip")
      view |> element("#done-#{link.id}") |> render_click()

      refute has_element?(view, "#link-#{link.id}")
      assert Library.get_link!(scope, link.id).triaged_at
    end

    test "other lists keep plain cards", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> ready()
      suggestion = suggestion_fixture(scope, link, %{proposed_name: "Pães"})

      {:ok, view, _html} = live(conn, ~p"/all")

      assert has_element?(view, "a#link-#{link.id}.card")
      refute has_element?(view, "#suggestion-#{suggestion.id}")
    end
  end

  describe "triage" do
    test "clicking a chip adds the link to that collection", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> ready()
      collection = collection_fixture(scope, %{name: "Receitas"})
      suggestion = suggestion_fixture(scope, link, %{collection_id: collection.id})

      {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")

      view |> element("#suggestion-#{suggestion.id}") |> render_click()

      assert has_element?(view, "#link-chip-#{collection.id}", "Receitas")
      assert has_element?(view, "#card-chip-#{link.id}-#{collection.id}", "Receitas")
      refute has_element?(view, "#suggestion-#{suggestion.id}")
      refute has_element?(view, "#link-suggestion-#{suggestion.id}")
      assert status(suggestion) == :accepted
      assert has_element?(view, "#link-#{link.id}"), "accepting one doesn't finish the link"
    end

    test "a new name creates the collection, which appears in column 1", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> ready()
      suggestion = suggestion_fixture(scope, link, %{proposed_name: "Pães caseiros"})

      {:ok, view, _html} = live(conn, ~p"/inbox")

      view |> element("#suggestion-#{suggestion.id}") |> render_click()

      assert [collection] = Collections.list_collections(scope)
      assert collection.name == "Pães caseiros"
      assert has_element?(view, "#nav-collection-#{collection.id}", "Pães caseiros")
      assert has_element?(view, "#card-chip-#{link.id}-#{collection.id}")
    end

    test "accept all adds every suggestion and slides the card out", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> ready()
      collection = collection_fixture(scope, %{name: "Receitas"})
      suggestion_fixture(scope, link, %{collection_id: collection.id})
      suggestion_fixture(scope, link, %{proposed_name: "Pães"})

      {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")

      view |> element("#accept-all-#{link.id}") |> render_click()

      assert_patch(view, ~p"/inbox")
      refute has_element?(view, "#link-#{link.id}")
      assert Enum.sort(collection_names(scope, link)) == ["Pães", "Receitas"]
      assert Library.get_link!(scope, link.id).triaged_at
    end

    test "accept all from a card keeps another open link", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> ready()
      other = scope |> link_fixture() |> ready()
      suggestion_fixture(scope, link, %{proposed_name: "Um"})
      suggestion_fixture(scope, link, %{proposed_name: "Dois"})

      {:ok, view, _html} = live(conn, ~p"/inbox/l/#{other.id}")

      view |> element("#accept-all-#{link.id}") |> render_click()

      refute has_element?(view, "#link-#{link.id}")
      assert has_element?(view, "#column-link")
      assert has_element?(view, "#link-#{other.id}")
    end

    test "✓ finishes the link and dismisses the rest", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> ready()
      a = suggestion_fixture(scope, link, %{proposed_name: "Um"})
      b = suggestion_fixture(scope, link, %{proposed_name: "Dois"})

      {:ok, view, _html} = live(conn, ~p"/inbox")

      view |> element("#suggestion-#{a.id}") |> render_click()
      view |> element("#done-#{link.id}") |> render_click()

      refute has_element?(view, "#link-#{link.id}")
      assert status(a) == :accepted
      assert status(b) == :dismissed
      assert collection_names(scope, link) == ["Um"]
      assert has_element?(view, "#column-inbox .empty")
    end

    test "a stale suggestion flashes not found", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> ready()
      suggestion = suggestion_fixture(scope, link, %{proposed_name: "Um"})

      {:ok, view, _html} = live(conn, ~p"/inbox")
      {:ok, _} = Collections.accept_suggestion(scope, suggestion.id)

      assert render_click(view, "accept_suggestion", %{"id" => suggestion.id}) =~ "Not found."
      assert render_click(view, "dismiss_suggestion", %{"id" => "not-a-uuid"}) =~ "Not found."
      assert render_click(view, "finish", %{"id" => Ecto.UUID.generate()}) =~ "Not found."
    end

    test "another user's suggestion is never accepted", %{conn: conn} do
      other = Acervo.AccountsFixtures.user_scope_fixture()
      link = other |> link_fixture() |> ready()
      suggestion = suggestion_fixture(other, link, %{proposed_name: "Alheia"})

      {:ok, view, _html} = live(conn, ~p"/inbox")

      assert render_click(view, "accept_suggestion", %{"id" => suggestion.id}) =~ "Not found."
      assert render_click(view, "accept_all", %{"id" => link.id}) =~ "Not found."
      assert status(suggestion) == :pending
      assert Collections.list_collections(other) == []
    end

    test "forged ids for another user's link never touch it", %{conn: conn, scope: scope} do
      other = Acervo.AccountsFixtures.user_scope_fixture()
      theirs = other |> link_fixture() |> ready()
      existing = collection_fixture(other, %{name: "Deles"})
      a = suggestion_fixture(other, theirs, %{collection_id: existing.id})
      b = suggestion_fixture(other, theirs, %{proposed_name: "Alheia"})
      mine = scope |> link_fixture() |> ready()

      {:ok, view, _html} = live(conn, ~p"/inbox/l/#{mine.id}")

      assert render_click(view, "finish", %{"id" => theirs.id}) =~ "Not found."
      assert render_click(view, "accept_all", %{"id" => theirs.id}) =~ "Not found."
      assert render_click(view, "finish", %{"id" => "not-a-uuid"}) =~ "Not found."
      assert render_click(view, "accept_all", %{"id" => "not-a-uuid"}) =~ "Not found."

      assert status(a) == :pending
      assert status(b) == :pending
      refute Repo.get!(Link, theirs.id).triaged_at
      assert other |> Collections.list_collections() |> Enum.map(& &1.name) == ["Deles"]
      assert collection_names(other, theirs) == []
      assert has_element?(view, "#link-#{mine.id}")
    end
  end

  describe "live updates" do
    test "suggestions landing re-render an open inbox", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> ready(enrichment_status: :pending)

      {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")
      assert has_element?(view, "#link-#{link.id} .is-waiting")

      {:ok, [suggestion]} = Collections.replace_suggestions(scope, link, [%{proposed_name: "Novidade", reason: "Novo"}])
      link |> Link.enrichment_changeset(%{enrichment_status: :ready}) |> Repo.update!()
      :ok = Library.broadcast_updated(scope, link.id)

      assert has_element?(view, "#suggestion-#{suggestion.id}", "Novidade")
      assert has_element?(view, "#link-suggestion-#{suggestion.id}", "Novidade")
      refute has_element?(view, "#link-#{link.id} .is-waiting")
    end
  end
end
