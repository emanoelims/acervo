defmodule AcervoWeb.ImportTest do
  use AcervoWeb.ConnCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures
  import Phoenix.LiveViewTest

  alias Acervo.Collections
  alias Acervo.Library
  alias Acervo.Library.BookmarkImport
  alias Acervo.Library.BookmarkImports
  alias Acervo.Library.Bookmarks

  @fixtures Path.expand("../../support/fixtures/bookmarks", __DIR__)

  setup :register_and_log_in_user

  defp chrome_html, do: @fixtures |> Path.join("chrome.html") |> File.read!()

  defp upload(view, name, content, type \\ "text/html") do
    view
    |> file_input("#import-form", :bookmarks, [%{name: name, content: content, type: type}])
    |> render_upload(name)
  end

  # Progress reaches the column through `send_update/3`, a message the view
  # sends itself: a second render waits for it.
  defp drain(view) do
    assert %{failure: 0} = Oban.drain_queue(queue: :import, with_recursion: true, with_safety: false)
    render(view)
  end

  defp pressed?(view, row, choice), do: has_element?(view, "#import-choice-#{row}-#{choice}[aria-pressed=true]")

  test "the dock's settings open the import column", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#dock-import") |> render_click()
    assert_patch(view, ~p"/import")

    assert has_element?(view, "#column-import #import-help-chromium")
    assert has_element?(view, "#column-import #import-help-safari")
    assert has_element?(view, "#column-import #import-help-firefox")
    assert has_element?(view, "#column-import #import-drop[phx-drop-target]")
    assert page_title(view) =~ "Import bookmarks"
  end

  test "upload, preview, choose and import, with live progress", %{conn: conn, scope: scope} do
    link_fixture(scope, "https://hexdocs.pm/elixir/Kernel.html")
    {:ok, view, _html} = live(conn, ~p"/import")

    upload(view, "bookmarks.html", chrome_html())

    # Totals: one link of six is already saved.
    assert view |> element("#import-found") |> render() =~ "6"
    assert view |> element("#import-existing") |> render() =~ "1"
    assert view |> element("#import-new") |> render() =~ "5"

    # Folders default to a collection; loose links to the inbox.
    assert view |> element("#import-folder-f0 .import-folder-name") |> render() =~ "Bookmarks bar / Dev"
    assert view |> element("#import-folder-f2 .import-folder-name") |> render() =~ "Receitas &amp; Viagens"
    assert pressed?(view, "f0", "collection")
    assert pressed?(view, "loose", "inbox")
    refute has_element?(view, "#import-choice-loose-collection:not([disabled])")
    assert view |> element("#import-estimate") |> render() =~ "0.10"

    # Skip one folder, send another to the inbox.
    view |> element("#import-choice-f2-skip") |> render_click()
    view |> element("#import-choice-f0-inbox") |> render_click()
    assert pressed?(view, "f2", "skip")
    assert pressed?(view, "f0", "inbox")
    assert view |> element("#import-new") |> render() =~ "4"

    # Nothing is written until Import.
    assert Library.count_links(scope) == 1

    view |> element("#import-start") |> render_click()
    assert has_element?(view, "#import-progress.is-running")
    assert has_element?(view, "#import-stop")
    refute has_element?(view, "#import-preview")

    drain(view)

    assert has_element?(view, "#import-progress.is-done")
    assert view |> element("#import-processed") |> render() =~ "5 / 5"
    assert view |> element("#import-created") |> render() =~ "4 new"
    refute has_element?(view, "#import-stop")
    # Done: another file can be imported.
    assert has_element?(view, "#import-drop")

    assert Library.count_links(scope) == 5
    assert [%{name: "Elixir", link_count: 2}] = Collections.list_collections(scope)
    # The root column follows: three new inbox links.
    assert view |> element("#nav-inbox .nav-count") |> render() =~ "4"
  end

  test "Stop ends the running import", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/import")
    upload(view, "bookmarks.html", chrome_html())
    view |> element("#import-start") |> render_click()

    view |> element("#import-stop") |> render_click()

    assert has_element?(view, "#import-progress.is-cancelled")
    assert BookmarkImports.latest(scope).status == :cancelled
    drain(view)
    assert Library.count_links(scope) == 0
  end

  test "reopening the column shows the running import", %{conn: conn, scope: scope} do
    parsed = Bookmarks.parse(chrome_html())
    {:ok, _import} = BookmarkImports.start(scope, parsed, %{0 => :collection, :loose => :inbox})

    {:ok, view, _html} = live(conn, ~p"/import")

    assert has_element?(view, "#import-progress.is-running")
    assert view |> element("#import-processed") |> render() =~ "0 / 3"
    refute has_element?(view, "#import-drop")
  end

  test "another user neither sees nor stops an import", %{conn: conn, scope: scope} do
    other = user_scope_fixture()
    {:ok, import} = BookmarkImports.start(other, Bookmarks.parse(chrome_html()), %{:loose => :inbox})

    {:ok, view, _html} = live(conn, ~p"/import")

    refute has_element?(view, "#import-progress")
    assert has_element?(view, "#import-drop")
    view |> with_target("#import") |> render_click("stop", %{})

    drain(view)
    refute has_element?(view, "#import-progress")
    assert Acervo.Repo.get!(BookmarkImport, import.id).status == :done
    assert Library.count_links(scope) == 0
  end

  test "a file that isn't .html is rejected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/import")

    assert {:error, [[_ref, :not_accepted]]} = upload(view, "bookmarks.json", "{}", "application/json")
  end

  test "a file over 10 MB is rejected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/import")

    big = String.duplicate("a", 10_000_001)
    assert {:error, [[_ref, :too_large]]} = upload(view, "bookmarks.html", big)
  end

  test "an HTML file that isn't a bookmarks export says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/import")

    upload(view, "page.html", "<html><body><p>Hello</p></body></html>")
    assert view |> element("#import-error") |> render() =~ "That isn&#39;t a bookmarks file."
    refute has_element?(view, "#import-preview")
  end

  test "a bookmarks file without http(s) links says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/import")

    upload(view, "bookmarks.html", ~s|<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><p><DT><A HREF="place:x">x</A></DL>|)
    assert view |> element("#import-error") |> render() =~ "No links found"
  end

  test "folder names render escaped", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/import")

    html =
      ~s|<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><p><DT><H3>&lt;img src=x onerror=alert(1)&gt;</H3>| <>
        ~s|<DL><p><DT><A HREF="https://x.example.com/">x</A></DL></DL>|

    upload(view, "bookmarks.html", html)

    assert view |> element("#import-folder-f0 .import-folder-name") |> render() =~ "&lt;img src=x"
    refute has_element?(view, "#import-folder-f0 img")
  end

  test "Choose another file goes back to the upload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/import")
    upload(view, "bookmarks.html", chrome_html())

    view |> element("#import-reset") |> render_click()

    refute has_element?(view, "#import-preview")
    assert has_element?(view, "#import-drop")
  end
end
