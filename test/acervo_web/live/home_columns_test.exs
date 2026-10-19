defmodule AcervoWeb.HomeColumnsTest do
  use AcervoWeb.ConnCase, async: true

  import Acervo.CollectionsFixtures
  import Acervo.LibraryFixtures
  import Phoenix.LiveViewTest

  alias Acervo.Collections
  alias Acervo.Library
  alias Acervo.Repo

  setup :register_and_log_in_user

  defp filed_link(scope, collection, attrs \\ %{}) do
    link =
      scope
      |> collection_link_fixture()
      |> Ecto.Changeset.change(Map.merge(%{title: "Filed", status: :ready}, Map.new(attrs)))
      |> Repo.update!()

    :ok = Collections.add_link(scope, collection, link)
    {:ok, link} = Library.mark_triaged(scope, link)
    link
  end

  defp column_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#home-columns > section")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))
  end

  test "the home shows the inbox, then each collection with links, in order", %{conn: conn, scope: scope} do
    waiting = link_fixture(scope)
    second = collection_fixture(scope, %{name: "Second", position: 1})
    first = collection_fixture(scope, %{name: "First", position: 0})
    empty = collection_fixture(scope, %{name: "Empty", position: 0})
    a = filed_link(scope, first, title: "Alpha")
    filed_link(scope, second, title: "Beta")

    {:ok, view, html} = live(conn, ~p"/")

    assert column_ids(html) == ["home-inbox", "home-collection-#{first.id}", "home-collection-#{second.id}"]
    assert has_element?(view, "#home-inbox .column-title", "Inbox")
    assert has_element?(view, "#home-inbox-link-#{waiting.id}.card-compact")
    assert has_element?(view, "#home-collection-#{first.id} .column-title", "First")
    assert has_element?(view, "#home-collection-#{first.id} .column-count", "1")
    assert has_element?(view, "#home-collection-#{first.id}-link-#{a.id}.card-compact", "Alpha")
    assert has_element?(view, "#home-collection-#{first.id}-all", "See all (1)")
    refute has_element?(view, "#home-collection-#{empty.id}")
    refute has_element?(view, "#column-all")
  end

  test "an empty archive shows only the root column", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#home-columns")
  end

  test "a card opens the link with its collection as the list", %{conn: conn, scope: scope} do
    collection = collection_fixture(scope, %{name: "Reads"})
    link = filed_link(scope, collection)

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#home-collection-#{collection.id}-link-#{link.id}") |> render_click()

    assert_patch(view, ~p"/c/#{collection.slug}/l/#{link.id}")
    assert has_element?(view, "#column-collection #link-#{link.id}.is-selected")
    assert has_element?(view, "#column-link")
    refute has_element?(view, "#home-columns")
  end

  test "an inbox card opens the link in the inbox", %{conn: conn, scope: scope} do
    link = link_fixture(scope)

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#home-inbox-link-#{link.id}") |> render_click()

    assert_patch(view, ~p"/inbox/l/#{link.id}")
    assert has_element?(view, "#column-inbox")
    assert has_element?(view, "#column-link")
  end

  test "“See all” opens the collection", %{conn: conn, scope: scope} do
    collection = collection_fixture(scope, %{name: "Reads"})
    filed_link(scope, collection)

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#home-collection-#{collection.id}-all") |> render_click()

    assert_patch(view, ~p"/c/#{collection.slug}")
    assert has_element?(view, "#column-collection")
  end

  test "returning home brings the columns back", %{conn: conn, scope: scope} do
    collection = collection_fixture(scope)
    filed_link(scope, collection)

    {:ok, view, _html} = live(conn, ~p"/all")
    refute has_element?(view, "#home-columns")

    view |> element("#dock-home") |> render_click()
    assert_patch(view, ~p"/")
    assert has_element?(view, "#home-collection-#{collection.id}")
  end

  describe "live updates" do
    test "a saved link appears in the inbox column", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#home-inbox")

      link = link_fixture(scope)
      assert has_element?(view, "#home-inbox-link-#{link.id}")

      %{created: [a, b]} = Library.save_links(scope, [unique_link_url(), unique_link_url()])
      assert has_element?(view, "#home-inbox-link-#{a.id}")
      assert has_element?(view, "#home-inbox-link-#{b.id}")
      assert has_element?(view, "#home-inbox .column-count", "3")
    end

    test "filing a link moves it from the inbox to its collection", %{conn: conn, scope: scope} do
      link = link_fixture(scope)
      collection = collection_fixture(scope, %{name: "Reads"})

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#home-collection-#{collection.id}")

      :ok = Collections.add_link(scope, collection, link)
      assert has_element?(view, "#home-collection-#{collection.id}-link-#{link.id}")
      assert has_element?(view, "#home-inbox-link-#{link.id}")

      {:ok, _link} = Library.mark_triaged(scope, link)
      refute has_element?(view, "#home-inbox")
      assert has_element?(view, "#home-collection-#{collection.id}-link-#{link.id}")
    end

    test "an updated link refreshes its card", %{conn: conn, scope: scope} do
      collection = collection_fixture(scope)
      link = filed_link(scope, collection, title: "Before")

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#home-collection-#{collection.id}-link-#{link.id}", "Before")

      link |> Ecto.Changeset.change(title: "After") |> Repo.update!()
      :ok = Library.broadcast_updated(scope, link.id)

      assert has_element?(view, "#home-collection-#{collection.id}-link-#{link.id}", "After")
    end

    test "removing a collection's last link removes its column", %{conn: conn, scope: scope} do
      collection = collection_fixture(scope)
      kept = collection_fixture(scope)
      link = filed_link(scope, collection)
      other = filed_link(scope, kept)

      {:ok, view, _html} = live(conn, ~p"/")

      :ok = Collections.remove_link(scope, collection, link)
      refute has_element?(view, "#home-collection-#{collection.id}")
      assert has_element?(view, "#home-collection-#{kept.id}-link-#{other.id}")

      {:ok, _link} = Library.delete_link(scope, other)
      refute has_element?(view, "#home-columns")
    end

    test "a renamed collection renames its column", %{conn: conn, scope: scope} do
      collection = collection_fixture(scope, %{name: "Old"})
      link = filed_link(scope, collection)

      {:ok, view, _html} = live(conn, ~p"/")
      {:ok, _collection} = Collections.update_collection(scope, collection, %{"name" => "New"})

      assert has_element?(view, "#home-collection-#{collection.id} .column-title", "New")
      assert has_element?(view, "#home-collection-#{collection.id}-link-#{link.id}[href='/c/new/l/#{link.id}']")
    end
  end
end
