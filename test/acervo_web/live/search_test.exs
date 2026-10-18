defmodule AcervoWeb.SearchTest do
  use AcervoWeb.ConnCase, async: true

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures
  import Acervo.LibraryFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Acervo.FakeEmbedder
  alias Acervo.Library.Link
  alias Acervo.Repo

  setup :register_and_log_in_user

  # A ready link with this title, `age` minutes old. Searches match it by text;
  # the fake embedder's vectors for unrelated texts are past the cutoff.
  defp link(scope, title, age \\ 0) do
    link = link_fixture(scope)
    inserted_at = :second |> DateTime.utc_now() |> DateTime.shift(minute: -age)

    Repo.update_all(from(l in Link, where: l.id == ^link.id),
      set: [status: :ready, title: title, inserted_at: inserted_at]
    )

    Repo.get!(Link, link.id)
  end

  defp in_collection(link, scope, collection) do
    :ok = Acervo.Collections.add_link(scope, collection, link)
    link
  end

  defp fail_embedding, do: FakeEmbedder.stub(fn _model, _text, _opts -> {:error, {:http, 500}} end)

  defp search(view, q) do
    view |> form("#search-form", %{"q" => q}) |> render_change()
    view
  end

  describe "the pill" do
    test "the dock's search item toggles it, and Escape closes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#search-pill")

      view |> element("#dock-search") |> render_click()
      assert has_element?(view, "#search-pill #search-form input#search-query[name='q'][phx-debounce='250']")
      assert has_element?(view, "#search-query[aria-label='Search']")
      assert has_element?(view, "#dock-search[aria-expanded='true']")

      view |> element("#dock-search") |> render_click()
      refute has_element?(view, "#search-pill")

      view |> element("#dock-search") |> render_click()
      view |> element("#search-pill") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#search-pill")
    end

    test "/ and ⌘K reach it through the page's shortcuts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#columns") |> render_hook("open_search", %{})
      assert has_element?(view, "#search-pill")
      # Opening it again keeps it open (the hook then focuses the field).
      view |> element("#columns") |> render_hook("open_search", %{})
      assert has_element?(view, "#search-pill")

      view |> element("#columns") |> render_hook("toggle_search", %{})
      refute has_element?(view, "#search-pill")
    end

    test "it replaces the add pill, and the add pill replaces it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#dock-add") |> render_click()
      view |> element("#dock-search") |> render_click()
      assert has_element?(view, "#search-pill")
      refute has_element?(view, "#add-pill")

      view |> element("#dock-add") |> render_click()
      assert has_element?(view, "#add-pill")
      refute has_element?(view, "#search-pill")
    end
  end

  describe "searching" do
    test "typing patches to /search?q= and lists the matches once they arrive", %{conn: conn, scope: scope} do
      beach = link(scope, "Praia do Forte")
      other = link(scope, "Mountain trail")
      {:ok, view, _html} = live(conn, ~p"/all")

      view |> element("#dock-search") |> render_click()
      search(view, "praia")

      assert_patch(view, ~p"/search?q=praia")
      assert render_async(view) =~ "Praia do Forte"
      assert has_element?(view, "#column-search .column-title", "praia")
      assert has_element?(view, "#column-search #links #link-#{beach.id}")
      refute has_element?(view, "#links #link-#{other.id}")
      assert has_element?(view, "#search-status[aria-live='polite']", "One result")
      assert has_element?(view, "#dock-search.is-active")
      refute has_element?(view, "#search-partial")
      refute has_element?(view, "#search-empty")
    end

    # Holds the embedding of each query until the test releases it.
    defp gate_embeddings do
      test = self()

      FakeEmbedder.stub(fn _model, text, _opts ->
        send(test, {:embedding, text, self()})

        receive do
          {:release, ^text} -> {:ok, FakeEmbedder.axis(1)}
        after
          5_000 -> {:error, :gate}
        end
      end)
    end

    test "a result that arrives after the query changed is not shown", %{conn: conn, scope: scope} do
      gate_embeddings()
      beach = link(scope, "Praia do Forte")
      fort = link(scope, "Forte de Copacabana")
      {:ok, view, _html} = live(conn, ~p"/all")

      view |> element("#dock-search") |> render_click()
      search(view, "praia")
      assert_receive {:embedding, "praia", old}
      search(view, "copacabana")
      assert_receive {:embedding, "copacabana", new}

      send(new, {:release, "copacabana"})
      render_async(view)
      assert has_element?(view, "#links #link-#{fort.id}")

      send(old, {:release, "praia"})
      render_async(view)
      assert has_element?(view, "#links #link-#{fort.id}")
      refute has_element?(view, "#links #link-#{beach.id}")
    end

    test "leaving a search mid-flight stops the spinner", %{conn: conn, scope: scope} do
      gate_embeddings()
      link(scope, "Praia do Forte")
      {:ok, view, _html} = live(conn, ~p"/all")

      view |> element("#dock-search") |> render_click()
      search(view, "praia")
      assert_receive {:embedding, "praia", task}
      assert has_element?(view, "#search-pill .is-loading")

      view |> element("#dock-home") |> render_click()
      assert_patch(view, ~p"/")
      render_patch(view, ~p"/all")
      view |> element("#dock-search") |> render_click()
      view |> element("#dock-search") |> render_click()
      assert has_element?(view, "#search-pill")
      refute has_element?(view, "#search-pill .is-loading")

      # The old result arrives later and is dropped.
      send(task, {:release, "praia"})
      render_async(view)
      refute has_element?(view, "#search-pill .is-loading")
      refute has_element?(view, "#search-empty")
    end

    test "refining replaces the URL and the results", %{conn: conn, scope: scope} do
      beach = link(scope, "Praia do Forte")
      fort = link(scope, "Forte de Copacabana")
      {:ok, view, _html} = live(conn, ~p"/search?q=praia")
      render_async(view)
      assert has_element?(view, "#links #link-#{beach.id}")

      search(view, "copacabana")
      assert_patch(view, ~p"/search?q=copacabana")
      render_async(view)
      assert has_element?(view, "#links #link-#{fort.id}")
      refute has_element?(view, "#links #link-#{beach.id}")
    end

    test "a query under 2 characters lists recent links", %{conn: conn, scope: scope} do
      old = link(scope, "Praia do Forte", 10)
      new = link(scope, "Mountain trail", 0)
      {:ok, view, _html} = live(conn, ~p"/search?q=p")

      assert has_element?(view, "#column-search .column-title", "Search")
      assert has_element?(view, "#links #link-#{old.id}")
      assert has_element?(view, "#links #link-#{new.id}")
      refute has_element?(view, "#search-empty")
      assert FakeEmbedder.calls() == 0
    end

    test "an empty query lists recent links", %{conn: conn, scope: scope} do
      saved = link(scope, "Praia do Forte")
      {:ok, view, _html} = live(conn, ~p"/search")

      assert has_element?(view, "#search-pill #search-query")
      assert has_element?(view, "#links #link-#{saved.id}")
      refute has_element?(view, "#search-empty")
    end

    test "a query with no match says so", %{conn: conn, scope: scope} do
      link(scope, "Praia do Forte")
      {:ok, view, _html} = live(conn, ~p"/search?q=xyzzy")

      render_async(view)
      assert has_element?(view, "#search-status #search-empty", "Nothing found.")
    end

    test "a failed query embedding still lists the text matches, flagged partial", %{conn: conn, scope: scope} do
      fail_embedding()
      beach = link(scope, "Praia do Forte")
      {:ok, view, _html} = live(conn, ~p"/search?q=praia")

      render_async(view)
      assert has_element?(view, "#links #link-#{beach.id}")
      assert has_element?(view, "#column-search #search-partial[title='Only matching words']")
    end

    test "matches by the query's vector too", %{conn: conn, scope: scope} do
      FakeEmbedder.stub(fn _model, _text, _opts -> {:ok, FakeEmbedder.axis(0)} end)
      dog = link(scope, "IMG_2041")

      Repo.update_all(from(l in Link, where: l.id == ^dog.id),
        set: [
          embedding: Pgvector.new(FakeEmbedder.axis(0)),
          embedding_model: Acervo.AI.embedding_model(),
          embedding_status: :ready
        ]
      )

      {:ok, view, _html} = live(conn, ~p"/search?q=um cachorro na praia")
      render_async(view)
      assert has_element?(view, "#links #link-#{dog.id}")
    end

    test "never lists another user's links", %{conn: conn, scope: scope} do
      mine = link(scope, "Praia do Forte")
      theirs = link(user_scope_fixture(), "Praia de Ipanema")
      {:ok, view, _html} = live(conn, ~p"/search?q=praia")

      render_async(view)
      assert has_element?(view, "#links #link-#{mine.id}")
      refute has_element?(view, "#link-#{theirs.id}")

      {:ok, view, _html} = live(conn, ~p"/search?q=p")
      refute has_element?(view, "#link-#{theirs.id}")

      assert {:error, {:live_redirect, %{to: "/search?q=praia", flash: %{"error" => "Not found."}}}} =
               live(conn, ~p"/search/l/#{theirs.id}?q=praia")
    end
  end

  describe "the URL" do
    test "a reload keeps the query, its scope and its results", %{conn: conn, scope: scope} do
      collection = collection_fixture(scope, %{name: "Viagens"})
      inside = scope |> link("Praia do Forte") |> in_collection(scope, collection)
      outside = link(scope, "Praia de Ipanema")

      {:ok, view, _html} = live(conn, ~p"/search?q=praia&in=#{collection.slug}")
      render_async(view)

      assert has_element?(view, "#search-query[value='praia']")
      assert has_element?(view, "#search-scope", "Viagens")
      assert has_element?(view, "#links #link-#{inside.id}")
      refute has_element?(view, "#links #link-#{outside.id}")
    end

    test "an unknown scope drops it", %{conn: conn} do
      theirs = collection_fixture(user_scope_fixture(), %{name: "Theirs"})

      for slug <- ["unknown", theirs.slug] do
        assert {:error, {:live_redirect, %{to: "/search?q=x", flash: %{"error" => "Not found."}}}} =
                 live(conn, ~p"/search?q=x&in=#{slug}")
      end
    end

    test "opening a result keeps the query and doesn't search again", %{conn: conn, scope: scope} do
      fail_embedding()
      beach = link(scope, "Praia do Forte")
      {:ok, view, _html} = live(conn, ~p"/search?q=praia")
      render_async(view)
      calls = FakeEmbedder.calls()

      view |> element("a#link-#{beach.id}[href='/search/l/#{beach.id}?q=praia']") |> render_click()
      assert_patch(view, ~p"/search/l/#{beach.id}?q=praia")
      render_async(view)

      assert has_element?(view, "#column-link")
      assert has_element?(view, "#column-search #links #link-#{beach.id}")
      assert FakeEmbedder.calls() == calls
    end

    test "a result's page column stays under the search", %{conn: conn, scope: scope} do
      beach = link(scope, "Praia do Forte")
      Repo.update_all(from(l in Link, where: l.id == ^beach.id), set: [embeddable: false])
      {:ok, view, _html} = live(conn, ~p"/search/l/#{beach.id}/web?q=praia")
      render_async(view)

      assert has_element?(view, "#column-web")
      assert has_element?(view, "#web-close[href='/search/l/#{beach.id}?q=praia']")
      # A result opens without the pill, to keep the page in view.
      refute has_element?(view, "#search-pill")
    end
  end

  describe "scope" do
    test "searching from a collection is scoped to it, and ✕ widens it", %{conn: conn, scope: scope} do
      collection = collection_fixture(scope, %{name: "Viagens"})
      inside = scope |> link("Praia do Forte") |> in_collection(scope, collection)
      outside = link(scope, "Praia de Ipanema")
      {:ok, view, _html} = live(conn, ~p"/c/#{collection.slug}")

      view |> element("#dock-search") |> render_click()
      assert has_element?(view, "#search-scope", "Viagens")

      search(view, "praia")
      assert_patch(view, ~p"/search?q=praia&in=#{collection.slug}")
      render_async(view)
      assert has_element?(view, "#links #link-#{inside.id}")
      refute has_element?(view, "#links #link-#{outside.id}")
      refute has_element?(view, "#collection-menu")

      view |> element("#search-scope-clear") |> render_click()
      assert_patch(view, ~p"/search?q=praia")
      render_async(view)
      refute has_element?(view, "#search-scope")
      assert has_element?(view, "#links #link-#{inside.id}")
      assert has_element?(view, "#links #link-#{outside.id}")
    end

    test "dropping the scope before typing searches everything", %{conn: conn, scope: scope} do
      collection = collection_fixture(scope, %{name: "Viagens"})
      {:ok, view, _html} = live(conn, ~p"/c/#{collection.slug}")

      view |> element("#dock-search") |> render_click()
      view |> element("#search-scope-clear") |> render_click()
      refute has_element?(view, "#search-scope")

      search(view, "praia")
      assert_patch(view, ~p"/search?q=praia")
    end

    test "a deleted scope collection drops the scope", %{conn: conn, scope: scope} do
      collection = collection_fixture(scope, %{name: "Viagens"})
      {:ok, view, _html} = live(conn, ~p"/search?q=praia&in=#{collection.slug}")

      {:ok, _} = Acervo.Collections.delete_collection(scope, collection)
      assert_patch(view, ~p"/search?q=praia")
    end
  end

  describe "live updates" do
    test "an update refreshes a listed card; a new link isn't added", %{conn: conn, scope: scope} do
      beach = link(scope, "Praia do Forte")
      {:ok, view, _html} = live(conn, ~p"/search?q=praia")
      render_async(view)

      Repo.update_all(from(l in Link, where: l.id == ^beach.id), set: [title: "Praia do Forte, Bahia"])
      send(view.pid, {:link_updated, %{id: beach.id}})
      assert has_element?(view, "#link-#{beach.id}", "Praia do Forte, Bahia")

      new = link(scope, "Praia nova")
      send(view.pid, {:link_created, Repo.preload(new, [:collections])})
      refute has_element?(view, "#link-#{new.id}")
    end
  end

  describe "the guide" do
    test "describes search and its shortcuts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/guide")

      assert has_element?(view, "#guide-search")
      assert has_element?(view, "#guide-key-search kbd", "/")
      assert has_element?(view, "#guide-key-search-anywhere kbd", "K")
    end
  end
end
