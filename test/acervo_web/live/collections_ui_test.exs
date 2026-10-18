defmodule AcervoWeb.CollectionsUITest do
  use AcervoWeb.ConnCase, async: true

  import Acervo.CollectionsFixtures
  import Acervo.LibraryFixtures
  import Phoenix.LiveViewTest

  alias Acervo.AccountsFixtures
  alias Acervo.Collections
  alias Acervo.Library

  setup :register_and_log_in_user

  defp names(link_collections), do: link_collections |> Enum.map(& &1.name) |> Enum.sort()

  defp collections_of(scope, link), do: names(Library.get_link!(scope, link.id).collections)

  describe "managing collections" do
    test "the + in column 1 creates a collection and opens it", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#new-collection") |> render_click()
      assert has_element?(view, "#new-collection-form")

      view |> form("#new-collection-form", %{"collection" => %{"name" => "Receitas"}}) |> render_submit()

      assert [collection] = Collections.list_collections(scope)
      assert collection.name == "Receitas"
      assert_patch(view, ~p"/c/receitas")
      refute has_element?(view, "#new-collection-form")
      assert has_element?(view, "#nav-collection-#{collection.id}", "Receitas")
      assert has_element?(view, "#column-collection", "Receitas")
    end

    test "blurring the name creates it once, even when Enter follows", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#new-collection") |> render_click()
      view |> element("#new-collection-name") |> render_blur(%{"value" => "Receitas"})
      assert_patch(view, ~p"/c/receitas")

      render_hook(view, "create_collection", %{"collection" => %{"name" => "Receitas"}})

      assert [_] = Collections.list_collections(scope)
      refute has_element?(view, "#new-collection-form")
    end

    test "blurring a blank name closes the field", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#new-collection") |> render_click()
      view |> element("#new-collection-name") |> render_blur(%{"value" => "  "})

      refute has_element?(view, "#new-collection-form")
      assert Collections.list_collections(scope) == []
    end

    test "creating shows errors inline", %{conn: conn, scope: scope} do
      collection_fixture(scope, %{name: "Receitas"})
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#new-collection") |> render_click()
      view |> form("#new-collection-form", %{"collection" => %{"name" => "receitas"}}) |> render_submit()

      assert has_element?(view, "#new-collection-form .field-error")
      assert [_] = Collections.list_collections(scope)
    end

    test "rename follows the new slug", %{conn: conn, scope: scope} do
      collection = collection_fixture(scope, %{name: "Receitas"})
      {:ok, view, _html} = live(conn, ~p"/c/#{collection.slug}")

      assert has_element?(view, "#column-collection #collection-menu")
      view |> element("#rename-collection") |> render_click()

      view
      |> form("#rename-collection-form", %{"collection" => %{"name" => "Cozinha"}})
      |> render_submit()

      assert_patch(view, ~p"/c/cozinha")
      refute has_element?(view, "#rename-collection-form")
      assert has_element?(view, "#column-collection .column-title", "Cozinha")
      assert has_element?(view, "#nav-collection-#{collection.id}", "Cozinha")
    end

    test "rename shows errors inline", %{conn: conn, scope: scope} do
      collection = collection_fixture(scope, %{name: "Receitas"})
      {:ok, view, _html} = live(conn, ~p"/c/#{collection.slug}")

      view |> element("#rename-collection") |> render_click()
      view |> form("#rename-collection-form", %{"collection" => %{"name" => ""}}) |> render_submit()

      assert has_element?(view, "#rename-collection-form .field-error")
    end

    test "a second submit after the rename is ignored", %{conn: conn, scope: scope} do
      collection = collection_fixture(scope, %{name: "Receitas"})
      {:ok, view, _html} = live(conn, ~p"/c/#{collection.slug}")

      view |> element("#rename-collection") |> render_click()
      view |> form("#rename-collection-form", %{"collection" => %{"name" => "Cozinha"}}) |> render_submit()
      assert_patch(view, ~p"/c/cozinha")

      render_hook(view, "save_collection", %{"collection" => %{"name" => "Outro"}})

      assert Collections.get_collection_by_slug!(scope, "cozinha").name == "Cozinha"
    end

    test "describe saves the description under the title", %{conn: conn, scope: scope} do
      collection = collection_fixture(scope, %{name: "Receitas"})
      {:ok, view, _html} = live(conn, ~p"/c/#{collection.slug}")

      view |> element("#describe-collection") |> render_click()

      view
      |> form("#describe-collection-form", %{"collection" => %{"description" => "Things to cook."}})
      |> render_submit()

      refute has_element?(view, "#describe-collection-form")
      assert has_element?(view, "#column-collection .desc", "Things to cook.")
      assert Collections.get_collection_by_slug!(scope, "receitas").description == "Things to cook."
    end

    test "delete removes the collection, keeps its links and goes home", %{conn: conn, scope: scope} do
      link = link_fixture(scope)
      collection = collection_fixture(scope, %{name: "Receitas"})
      :ok = Collections.add_link(scope, collection, link)

      {:ok, view, _html} = live(conn, ~p"/c/#{collection.slug}")

      assert has_element?(view, "#delete-collection[data-confirm]")
      view |> element("#delete-collection") |> render_click()

      assert_patch(view, ~p"/")
      assert Collections.list_collections(scope) == []
      refute has_element?(view, "#nav-collection-#{collection.id}")
      assert Library.get_link!(scope, link.id)
    end
  end

  describe "organizing a link" do
    test "the popover filters collections and adds the link to one", %{conn: conn, scope: scope} do
      link = link_fixture(scope)
      recipes = collection_fixture(scope, %{name: "Receitas"})
      trips = collection_fixture(scope, %{name: "Viagem"})

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      assert has_element?(view, "#link-add-collection")
      assert has_element?(view, "#collection-option-#{recipes.id}")
      assert has_element?(view, "#collection-option-#{trips.id}")
      refute has_element?(view, "#collection-create")

      view |> form("#collection-filter-form", %{"query" => "rece"}) |> render_change()
      assert has_element?(view, "#collection-option-#{recipes.id}")
      refute has_element?(view, "#collection-option-#{trips.id}")
      assert has_element?(view, "#collection-create", "rece")

      view |> form("#collection-filter-form", %{"query" => "RECEITAS"}) |> render_change()
      refute has_element?(view, "#collection-create")

      view |> element("#collection-option-#{recipes.id}") |> render_click()

      assert collections_of(scope, link) == ["Receitas"]
      assert has_element?(view, "#column-link #link-chip-#{recipes.id}", "Receitas")
      assert has_element?(view, "#nav-collection-#{recipes.id} .nav-count", "1")
    end

    test "the create row makes a new collection with the link in it", %{conn: conn, scope: scope} do
      link = link_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      view |> form("#collection-filter-form", %{"query" => "Leituras"}) |> render_change()
      view |> element("#collection-create") |> render_click()

      assert [collection] = Collections.list_collections(scope)
      assert collection.name == "Leituras"
      assert collections_of(scope, link) == ["Leituras"]
      assert has_element?(view, "#column-link #link-chip-#{collection.id}", "Leituras")
      refute has_element?(view, "#collection-create")
    end

    test "the chip ✕ removes the link from the collection", %{conn: conn, scope: scope} do
      link = link_fixture(scope)
      collection = collection_fixture(scope, %{name: "Receitas"})
      :ok = Collections.add_link(scope, collection, link)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      view |> element("#chip-remove-#{collection.id}") |> render_click()

      assert collections_of(scope, link) == []
      refute has_element?(view, "#link-chip-#{collection.id}")
    end

    test "clicking a checked row removes the link from that collection", %{conn: conn, scope: scope} do
      link = link_fixture(scope)
      collection = collection_fixture(scope, %{name: "Receitas"})
      :ok = Collections.add_link(scope, collection, link)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")
      assert has_element?(view, "#collection-option-#{collection.id}[aria-pressed='true']")

      view |> element("#collection-option-#{collection.id}") |> render_click()

      assert collections_of(scope, link) == []
      assert has_element?(view, "#collection-option-#{collection.id}[aria-pressed='false']")
    end

    test "Enter on an exact match for a collection the link is in is a no-op", %{conn: conn, scope: scope} do
      link = link_fixture(scope)
      collection = collection_fixture(scope, %{name: "Receitas"})
      :ok = Collections.add_link(scope, collection, link)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      view |> form("#collection-filter-form", %{"query" => "receitas"}) |> render_submit()

      assert collections_of(scope, link) == ["Receitas"]
      assert [_] = Collections.list_collections(scope)
    end

    test "a name colliding by slug shows the existing collection instead of nothing", %{conn: conn, scope: scope} do
      link = link_fixture(scope)
      c = collection_fixture(scope, %{name: "C"})

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      view |> form("#collection-filter-form", %{"query" => "C++"}) |> render_change()
      assert has_element?(view, "#collection-option-#{c.id}", "C")
      refute has_element?(view, "#collection-create")
      refute has_element?(view, ".pick-empty")

      view |> element("#collection-option-#{c.id}") |> render_click()
      assert collections_of(scope, link) == ["C"]
      assert [_] = Collections.list_collections(scope)
    end

    test "a name with no letters or numbers shows an error in the picker", %{conn: conn, scope: scope} do
      link = link_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      view |> form("#collection-filter-form", %{"query" => "!!!"}) |> render_change()
      view |> element("#collection-create") |> render_click()

      assert has_element?(view, "#collection-options #collection-error", "Couldn't create that collection.")
      assert Collections.list_collections(scope) == []
    end

    test "removing the link from the collection being viewed returns to its list", %{conn: conn, scope: scope} do
      link = link_fixture(scope)
      collection = collection_fixture(scope, %{name: "Receitas"})
      other = collection_fixture(scope, %{name: "Viagem"})
      :ok = Collections.add_link(scope, collection, link)
      :ok = Collections.add_link(scope, other, link)

      {:ok, view, _html} = live(conn, ~p"/c/#{collection.slug}/l/#{link.id}")

      view |> element("#chip-remove-#{other.id}") |> render_click()
      assert render(view) =~ "chip-remove-#{collection.id}"
      assert has_element?(view, "#column-link")

      view |> element("#chip-remove-#{collection.id}") |> render_click()
      assert_patch(view, ~p"/c/#{collection.slug}")
      refute has_element?(view, "#column-link")
      assert collections_of(scope, link) == []
    end

    test "the picker toggle on the viewed collection returns to its list", %{conn: conn, scope: scope} do
      link = link_fixture(scope)
      collection = collection_fixture(scope, %{name: "Receitas"})
      :ok = Collections.add_link(scope, collection, link)

      {:ok, view, _html} = live(conn, ~p"/c/#{collection.slug}/l/#{link.id}")

      view |> element("#collection-option-#{collection.id}") |> render_click()

      assert_patch(view, ~p"/c/#{collection.slug}")
    end

    test "another user's collection id is ignored", %{conn: conn, scope: scope} do
      link = link_fixture(scope)
      other = collection_fixture(AccountsFixtures.user_scope_fixture(), %{name: "Secret"})

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      render_hook(view, "add_to_collection", %{"id" => other.id})

      assert collections_of(scope, link) == []
    end
  end
end
