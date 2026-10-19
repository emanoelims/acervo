defmodule AcervoWeb.RelatedLinksTest do
  use AcervoWeb.ConnCase, async: true

  import Acervo.LibraryFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Acervo.AccountsFixtures
  alias Acervo.AI
  alias Acervo.FakeEmbedder
  alias Acervo.Library
  alias Acervo.Library.Link
  alias Acervo.Repo

  setup :register_and_log_in_user

  # A ready link with this title and, with `vector`, an embedding.
  defp link(scope, title, vector \\ nil) do
    link = link_fixture(scope)

    embedding =
      if vector,
        do: [embedding: Pgvector.new(vector), embedding_model: AI.embedding_model(), embedding_status: :ready],
        else: []

    Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [status: :ready, title: title] ++ embedding)
    Repo.get!(Link, link.id)
  end

  defp near(weight), do: FakeEmbedder.blend([{0, 1.0}, {1, weight}])

  describe "related section" do
    test "lists the links related by hand first, then the similar ones", %{conn: conn, scope: scope} do
      source = link(scope, "Bees", FakeEmbedder.axis(0))
      manual = link(scope, "Hand picked", FakeEmbedder.axis(5))
      similar = link(scope, "Honey", near(0.1))
      _far = link(scope, "Trains", FakeEmbedder.axis(1))
      {:ok, _} = Library.relate(scope, source, manual)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{source.id}")
      render_async(view)

      assert has_element?(view, "#link-related #related-#{manual.id} .lucide-link")
      assert has_element?(view, "#link-related #related-card-#{manual.id}[href='/all/l/#{manual.id}']", "Hand picked")
      assert has_element?(view, "#link-related #similar-#{similar.id}", "Honey")
      refute has_element?(view, "#link-related", "Trains")
      refute has_element?(view, "#similar-#{manual.id}")

      html = view |> element("#link-related") |> render()
      {manual_at, _} = :binary.match(html, "related-card-#{manual.id}")
      {similar_at, _} = :binary.match(html, "similar-#{similar.id}")
      assert manual_at < similar_at
    end

    test "cards open the related link in the current list", %{conn: conn, scope: scope} do
      source = link(scope, "Bees", FakeEmbedder.axis(0))
      similar = link(scope, "Honey", near(0.1))

      {:ok, view, _html} = live(conn, ~p"/inbox/l/#{source.id}")
      render_async(view)

      view |> element("#similar-#{similar.id}") |> render_click()
      assert_patch(view, ~p"/inbox/l/#{similar.id}")
      render_async(view)
      assert has_element?(view, "#similar-#{source.id}")
    end

    test "shows at most five, and See more similar opens them all", %{conn: conn, scope: scope} do
      source = link(scope, "Bees", FakeEmbedder.axis(0))
      similar = for i <- 1..7, do: link(scope, "Hive #{i}", near(i / 20))

      {:ok, view, _html} = live(conn, ~p"/all/l/#{source.id}")
      render_async(view)

      assert view |> element("#link-related") |> render() |> String.split("class=\"card card-compact") |> length() == 6

      view |> element("#link-more-similar") |> render_click()
      assert_patch(view, ~p"/search/l/#{source.id}?similar=#{source.id}")
      render_async(view)

      assert has_element?(view, "#column-similar .column-title", "Similar to Bees")
      for link <- similar, do: assert(has_element?(view, "#column-similar #link-#{link.id}"))
      refute has_element?(view, "#column-similar #link-#{source.id}")
      assert has_element?(view, "#dock-search.is-active")

      [first | _] = similar
      view |> element("#column-similar #link-#{first.id}") |> render_click()
      assert_patch(view, ~p"/search/l/#{first.id}?similar=#{source.id}")
      assert has_element?(view, "#column-similar #link-#{first.id}.is-selected")
    end

    test "a link without an embedding shows only its manual relations", %{conn: conn, scope: scope} do
      source = link(scope, "Bees")
      manual = link(scope, "Hand picked")
      _similar = link(scope, "Honey", near(0.1))
      {:ok, _} = Library.relate(scope, source, manual)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{source.id}")
      render_async(view)

      assert has_element?(view, "#related-#{manual.id}")
      refute has_element?(view, "[id^=similar-]")
      refute has_element?(view, "#link-more-similar")
    end

    test "nothing related, no section", %{conn: conn, scope: scope} do
      source = link(scope, "Bees")

      {:ok, view, _html} = live(conn, ~p"/all/l/#{source.id}")
      render_async(view)

      refute has_element?(view, "#link-related")
    end

    test "✕ removes a relation", %{conn: conn, scope: scope} do
      source = link(scope, "Bees")
      manual = link(scope, "Hand picked")
      {:ok, _} = Library.relate(scope, source, manual)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{source.id}")
      render_async(view)

      view |> element("#related-remove-#{manual.id}") |> render_click()
      render_async(view)

      refute has_element?(view, "#related-#{manual.id}")
      assert Library.list_related(scope, source) == []
    end

    test "a relation made elsewhere shows up", %{conn: conn, scope: scope} do
      source = link(scope, "Bees")
      other = link(scope, "Wax")

      {:ok, view, _html} = live(conn, ~p"/all/l/#{source.id}")
      render_async(view)
      refute has_element?(view, "#related-#{other.id}")

      {:ok, _} = Library.relate(scope, other, source)
      render_async(view)
      assert has_element?(view, "#related-#{other.id}")
    end

    test "the similar list of another user's link is not found", %{conn: conn} do
      theirs = link_fixture(AccountsFixtures.user_scope_fixture())

      {:error, {:live_redirect, %{to: "/all"}}} = live(conn, ~p"/search?similar=#{theirs.id}")
    end
  end

  describe "relation picker" do
    test "finds links by their words, without the link itself or related ones", %{conn: conn, scope: scope} do
      source = link(scope, "Beekeeping basics")
      match = link(scope, "Beekeeping tools")
      related = link(scope, "Beekeeping history")
      _other = link(scope, "Trains")
      {:ok, _} = Library.relate(scope, source, related)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{source.id}")
      assert has_element?(view, "#link-relations summary#link-relate[aria-label='Relate a link']")
      refute has_element?(view, "[id^=relation-option-]")

      view |> form("#relation-filter-form", %{"query" => "beekeep"}) |> render_change()

      assert has_element?(view, "#relation-option-#{match.id}", "Beekeeping tools")
      refute has_element?(view, "#relation-option-#{source.id}")
      refute has_element?(view, "#relation-option-#{related.id}")

      view |> form("#relation-filter-form", %{"query" => "zebras"}) |> render_change()
      assert has_element?(view, "#relation-options .pick-empty", "Nothing found.")
    end

    test "a click relates the link, and ↩ relates the first match", %{conn: conn, scope: scope} do
      source = link(scope, "Beekeeping basics")
      match = link(scope, "Beekeeping tools")
      second = link(scope, "Wax candles")

      {:ok, view, _html} = live(conn, ~p"/all/l/#{source.id}")
      view |> form("#relation-filter-form", %{"query" => "beekeeping"}) |> render_change()
      view |> element("#relation-option-#{match.id}") |> render_click()
      render_async(view)

      assert has_element?(view, "#related-#{match.id}")
      refute has_element?(view, "[id^=relation-option-]")

      view |> form("#relation-filter-form", %{"query" => "candles"}) |> render_change()
      view |> form("#relation-filter-form", %{"query" => "candles"}) |> render_submit()
      render_async(view)

      assert has_element?(view, "#related-#{second.id}")
      assert scope |> Library.list_related(source) |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([match.id, second.id])
    end

    test "another user's link can't be related", %{conn: conn, scope: scope} do
      source = link(scope, "Beekeeping basics")
      theirs = link_fixture(AccountsFixtures.user_scope_fixture())

      {:ok, view, _html} = live(conn, ~p"/all/l/#{source.id}")
      render_hook(view, "relate_link", %{"id" => theirs.id})

      assert render(view) =~ "Not found."
      assert Library.list_related(scope, source) == []
    end
  end
end
