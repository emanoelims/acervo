defmodule AcervoWeb.LinkColumnTest do
  use AcervoWeb.ConnCase, async: true

  import Acervo.CollectionsFixtures
  import Acervo.LibraryFixtures
  import Phoenix.LiveViewTest

  alias Acervo.AccountsFixtures
  alias Acervo.Collections
  alias Acervo.Library
  alias Acervo.Library.Link
  alias Acervo.Repo

  setup :register_and_log_in_user

  defp capture(link, attrs) do
    link
    |> Link.capture_changeset(Enum.into(attrs, %{status: :ready}))
    |> Repo.update!()
  end

  describe "cards" do
    test "/all lists the user's links newest first, never another user's", %{conn: conn, scope: scope} do
      older = scope |> link_fixture() |> capture(title: "Older post")
      newer = scope |> link_fixture() |> capture(title: "Newer post")
      other = AccountsFixtures.user_scope_fixture() |> link_fixture() |> capture(title: "Not mine")

      {:ok, view, html} = live(conn, ~p"/all")

      assert has_element?(view, "#links #link-#{older.id}", "Older post")
      assert has_element?(view, "#links #link-#{newer.id}", "Newer post")
      refute has_element?(view, "#link-#{other.id}")
      refute html =~ "Not mine"

      {newer_at, _} = :binary.match(html, "link-#{newer.id}")
      {older_at, _} = :binary.match(html, "link-#{older.id}")
      assert newer_at < older_at
    end

    test "pending links show a skeleton with the host as the title", %{conn: conn, scope: scope} do
      link = link_fixture(scope, "https://pending.example.org/a")

      {:ok, view, _html} = live(conn, ~p"/all")

      assert has_element?(view, "#link-#{link.id} .skeleton")
      assert has_element?(view, "#link-#{link.id}", "pending.example.org")
    end

    test "image, video and failed links get their own card", %{conn: conn, scope: scope} do
      image = scope |> link_fixture() |> capture(title: "With image")
      collection_link_image_fixture(image)

      video = scope |> link_fixture("https://www.youtube.com/watch?v=abc123") |> capture(title: "A video")
      collection_link_image_fixture(video)

      failed = scope |> link_fixture("https://www.instagram.com/p/xyz/") |> capture(capture_error: "blocked")

      {:ok, view, _html} = live(conn, ~p"/all")

      assert has_element?(view, "#link-#{image.id} .glow img[src^='/images/']")
      assert has_element?(view, "#link-#{video.id} .media .play")
      assert has_element?(view, "#link-#{video.id} .src-youtube")
      assert has_element?(view, "#link-#{failed.id}.text .card-shot")
      assert has_element?(view, "#link-#{failed.id}", "instagram.com")
    end

    test "the lead links its counts to their lists", %{conn: conn, scope: scope} do
      link_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#column-root .lead a[href='/all']", "One link")
      assert has_element?(view, "#column-root .lead a[href='/inbox']")
    end
  end

  describe "the link column" do
    test "clicking a card patches to the link and opens its column", %{conn: conn, scope: scope} do
      link = scope |> link_fixture() |> capture(title: "Miller columns are back", author: "Che Wei Lee")

      {:ok, view, _html} = live(conn, ~p"/all")
      view |> element("#link-#{link.id}") |> render_click()

      assert_patch(view, ~p"/all/l/#{link.id}")
      assert has_element?(view, "#column-link", "Miller columns are back")
      assert has_element?(view, "#column-link .meta", "Che Wei Lee")
      assert has_element?(view, "#link-#{link.id}.is-selected")
      assert has_element?(view, "#link-open[target=_blank][rel='noopener noreferrer']")
      assert page_title(view) =~ "Miller columns are back"
    end

    test "opens the canonical URL and shows its host for a link saved without a scheme", %{conn: conn, scope: scope} do
      link = link_fixture(scope, "example.com/a")

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      assert has_element?(view, ~s|#link-open[href="https://example.com/a"]|)
      assert has_element?(view, "#column-link .meta", "example.com")
      assert has_element?(view, "#link-#{link.id}", "example.com")
    end

    test "leaving an open link for another list keeps the order", %{conn: conn, scope: scope} do
      older = link_fixture(scope)
      newer = link_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/inbox/l/#{newer.id}")
      view |> element("#nav-all") |> render_click()
      assert_patch(view, ~p"/all")

      ids = view |> render() |> then(&Regex.scan(~r/id="(link-[0-9a-f-]{36})"/, &1)) |> Enum.map(&List.last/1)
      assert ids == ["link-#{newer.id}", "link-#{older.id}"]
    end

    test "collections show as chips that patch to the collection", %{conn: conn, scope: scope} do
      link = link_fixture(scope)
      collection = collection_fixture(scope, %{name: "Elixir"})
      :ok = Collections.add_link(scope, collection, link)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      assert has_element?(view, "#column-link .chip[href='/c/#{collection.slug}']", "Elixir")
    end

    test "saving a note persists it", %{conn: conn, scope: scope} do
      link = link_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      view |> form("#note-form", link: %{note: "Read this twice"}) |> render_submit()
      assert Library.get_link!(scope, link.id).note == "Read this twice"

      view |> element("#note-form textarea") |> render_blur(%{"value" => "On blur"})
      assert Library.get_link!(scope, link.id).note == "On blur"
    end

    test "a note over 4000 characters shows its error inline", %{conn: conn, scope: scope} do
      link = link_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      view |> element("#note-form textarea") |> render_blur(%{"value" => String.duplicate("a", 4001)})

      assert has_element?(view, "#note-form", "should be at most 4000 character(s)")
      assert Library.get_link!(scope, link.id).note == nil
    end

    test "events without an open link are ignored", %{conn: conn, scope: scope} do
      link_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/all")

      for event <- ~w(done delete save_note) do
        render_hook(view, event, %{})
      end

      assert has_element?(view, "#links")
      assert Library.count_links(scope) == 1
    end

    test "done on the inbox marks the link triaged and leaves the column", %{conn: conn, scope: scope} do
      link = link_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")
      assert has_element?(view, "#links #link-#{link.id}")

      view |> element("#link-done") |> render_click()

      assert_patch(view, ~p"/inbox")
      refute has_element?(view, "#link-#{link.id}")
      refute has_element?(view, "#column-link")
      assert Library.get_link!(scope, link.id).triaged_at
    end

    test "done is hidden once the link is triaged", %{conn: conn, scope: scope} do
      link = link_fixture(scope)
      {:ok, _} = Library.mark_triaged(scope, link)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      refute has_element?(view, "#link-done")
    end

    test "delete removes the card", %{conn: conn, scope: scope} do
      link = link_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")
      assert has_element?(view, "#link-delete[data-confirm]")

      view |> element("#link-delete") |> render_click()

      assert_patch(view, ~p"/all")
      refute has_element?(view, "#link-#{link.id}")
      assert_raise Ecto.NoResultsError, fn -> Library.get_link!(scope, link.id) end
    end

    test "renaming the open collection follows the new slug and keeps the link open", %{conn: conn, scope: scope} do
      link = link_fixture(scope)
      collection = collection_fixture(scope, %{name: "Receitas"})
      :ok = Collections.add_link(scope, collection, link)

      {:ok, view, _html} = live(conn, ~p"/c/#{collection.slug}/l/#{link.id}")
      assert has_element?(view, "#link-#{link.id}[href='/c/#{collection.slug}/l/#{link.id}']")

      {:ok, renamed} = Collections.update_collection(scope, collection, %{name: "Cozinha"})
      refute renamed.slug == collection.slug

      assert_patch(view, ~p"/c/#{renamed.slug}/l/#{link.id}")
      assert has_element?(view, "#link-#{link.id}[href='/c/#{renamed.slug}/l/#{link.id}']")
      assert has_element?(view, "#column-link")
    end

    test "another user's link redirects to the list with an error", %{conn: conn} do
      other = link_fixture(AccountsFixtures.user_scope_fixture())

      assert {:error, {:live_redirect, %{to: "/all", flash: %{"error" => "Not found."}}}} =
               live(conn, ~p"/all/l/#{other.id}")

      assert {:error, {:live_redirect, %{to: "/all"}}} = live(conn, ~p"/all/l/not-a-uuid")
    end

    test "another user's collection redirects home with an error", %{conn: conn} do
      other = collection_fixture(AccountsFixtures.user_scope_fixture(), %{name: "Secret"})

      assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => "Not found."}}}} =
               live(conn, ~p"/c/#{other.slug}")
    end
  end

  describe "collections" do
    test "column 1 lists collections and opens them", %{conn: conn, scope: scope} do
      inside = scope |> link_fixture() |> capture(title: "Inside")
      outside = scope |> link_fixture() |> capture(title: "Outside")
      collection = collection_fixture(scope, %{name: "Receitas", description: "Things to cook."})
      :ok = Collections.add_link(scope, collection, inside)

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#nav-collection-#{collection.id} .nav-count", "1")

      view |> element("#nav-collection-#{collection.id}") |> render_click()
      assert_patch(view, ~p"/c/#{collection.slug}")

      assert has_element?(view, "#column-collection", "Things to cook.")
      assert has_element?(view, "#links #link-#{inside.id}")
      refute has_element?(view, "#link-#{outside.id}")

      view |> element("#link-#{inside.id}") |> render_click()
      assert_patch(view, ~p"/c/#{collection.slug}/l/#{inside.id}")
      assert has_element?(view, "#column-link")
    end
  end

  describe "live updates" do
    test "a created link appears at the top", %{conn: conn, scope: scope} do
      older = link_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/all")
      link = link_fixture(scope)

      assert has_element?(view, "#links #link-#{link.id}")

      [first | _] =
        view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#links [id^=link-]") |> LazyHTML.attribute("id")

      assert first == "link-#{link.id}"
      assert has_element?(view, "#link-#{older.id}")
      assert has_element?(view, "#nav-all .nav-count", "2")
      assert has_element?(view, "#nav-inbox .nav-count", "2")
    end

    test "an updated link re-renders its card and the open column", %{conn: conn, scope: scope} do
      link = link_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/all/l/#{link.id}")

      capture(link, title: "Captured title")
      :ok = Library.broadcast_updated(scope, link.id)
      assert has_element?(view, "#link-#{link.id}", "Captured title")
      assert has_element?(view, "#column-link", "Captured title")
    end

    test "a link triaged elsewhere leaves the inbox", %{conn: conn, scope: scope} do
      link = link_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/inbox")
      assert has_element?(view, "#link-#{link.id}")

      {:ok, _} = Library.mark_triaged(scope, link)

      refute has_element?(view, "#link-#{link.id}")
      refute has_element?(view, "#nav-inbox .nav-count", "1")
    end

    test "a deleted link disappears", %{conn: conn, scope: scope} do
      link = link_fixture(scope)

      {:ok, view, _html} = live(conn, ~p"/all")
      assert has_element?(view, "#link-#{link.id}")

      {:ok, _} = Library.delete_link(scope, link)

      refute has_element?(view, "#link-#{link.id}")
    end
  end

  describe "dates" do
    test "format per locale, falling back to when the link was saved" do
      date = ~U[2026-10-12 10:00:00Z]

      assert Gettext.with_locale(AcervoWeb.Gettext, "pt_BR", fn ->
               AcervoWeb.LinkComponents.format_date(date)
             end) == "12 out 2026"

      assert Gettext.with_locale(AcervoWeb.Gettext, "en", fn ->
               AcervoWeb.LinkComponents.format_date(date)
             end) == "Oct 12, 2026"

      assert AcervoWeb.LinkComponents.link_date(%Link{published_at: nil, inserted_at: date}) == date
    end
  end
end
