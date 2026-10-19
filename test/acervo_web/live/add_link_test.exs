defmodule AcervoWeb.AddLinkTest do
  use AcervoWeb.ConnCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.LibraryFixtures
  import Phoenix.LiveViewTest

  alias Acervo.Library

  setup :register_and_log_in_user

  defp open_pill(view) do
    view |> element("#dock-add") |> render_click()
    assert has_element?(view, "#add-pill #add-link-form input[name='url']")
    view
  end

  defp only_link(scope) do
    assert [link] = Library.list_links(scope, filter: :all)
    link
  end

  describe "the dock +" do
    test "toggles the floating pill, and Escape closes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#add-pill")

      open_pill(view)
      view |> element("#dock-add") |> render_click()
      refute has_element?(view, "#add-pill")

      open_pill(view)
      view |> element("#add-pill") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#add-pill")
    end

    test "submitting a URL saves it and opens it in the inbox", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> open_pill() |> form("#add-link-form", %{"url" => "https://example.com/a-post"}) |> render_submit()

      link = only_link(scope)
      assert link.canonical_url == "https://example.com/a-post"
      assert_patch(view, ~p"/inbox/l/#{link.id}")
      refute has_element?(view, "#add-pill")
      assert has_element?(view, "#column-inbox #links #link-#{link.id}")
      assert has_element?(view, "#column-link")
      assert render(view) =~ "Saved."
    end

    test "submitting a saved URL opens the existing link", %{conn: conn, scope: scope} do
      link = link_fixture(scope, "https://example.com/again")
      {:ok, _} = Library.mark_triaged(scope, link)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      view |> open_pill() |> form("#add-link-form", %{"url" => "example.com/again"}) |> render_submit()

      assert_patch(view, ~p"/all/l/#{link.id}")
      assert only_link(scope).id == link.id
      assert render(view) =~ "Already in your archive."
    end

    test "an invalid URL shows an error in the pill", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> open_pill() |> form("#add-link-form", %{"url" => "not a link"}) |> render_submit()

      assert has_element?(view, "#add-pill .field-error", "That doesn't look like a link.")
      assert has_element?(view, "#add-link-form input[name='url'][value='not a link']")
      assert Library.list_links(scope, filter: :all) == []
    end
  end

  describe "pasting" do
    test "the columns carry the paste hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#columns[phx-hook]")
    end

    test "a pasted URL is saved like a submitted one", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/all")

      view |> element("#columns") |> render_hook("add_link", %{"url" => "https://example.com/pasted"})

      link = only_link(scope)
      assert_patch(view, ~p"/inbox/l/#{link.id}")
      assert render(view) =~ "Saved."
    end

    test "pasting an untriaged saved URL opens it in the inbox", %{conn: conn, scope: scope} do
      link = link_fixture(scope, "https://example.com/waiting")

      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#columns") |> render_hook("add_link", %{"url" => "https://example.com/waiting"})

      assert_patch(view, ~p"/inbox/l/#{link.id}")
      assert render(view) =~ "Already in your archive."
    end

    test "a pasted invalid URL opens the pill with the error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#columns") |> render_hook("add_link", %{"url" => "nope"})

      assert has_element?(view, "#add-pill .field-error")
    end

    test "an over-length URL shows the error, empties the input and saves nothing", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/")
      url = "https://example.com/" <> String.duplicate("a", 2100)

      view |> element("#columns") |> render_hook("add_link", %{"url" => url})

      assert has_element?(view, "#add-pill .field-error", "That doesn't look like a link.")
      assert has_element?(view, "#add-link-form input[name='url'][value='']")
      assert Library.list_links(scope, filter: :all) == []
    end

    test "a non-string URL is ignored", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "add_link", %{"url" => %{"a" => "b"}})

      refute has_element?(view, "#add-pill")
      assert Library.list_links(scope, filter: :all) == []
    end
  end

  describe "pasting several links" do
    @list """
    Read later:
    https://example.com/one
    https://example.com/two,
    and https://example.com/three.
    """

    defp paste(view, text), do: view |> element("#columns") |> render_hook("add_link", %{"url" => text})

    test "saves every link, stays put and shows one summary", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/inbox")

      paste(view, @list)

      links = Library.list_links(scope, filter: :all)

      assert links |> Enum.map(& &1.canonical_url) |> Enum.sort() ==
               ["https://example.com/one", "https://example.com/three", "https://example.com/two"]

      assert length(all_enqueued(worker: Acervo.Library.CaptureLink)) == 3
      html = render(view)
      assert html =~ "3 links saved"
      refute html =~ "already in your archive"
      refute html =~ "Saved."
      assert has_element?(view, "#nav-inbox .nav-count", "3")
      for link <- links, do: assert(has_element?(view, "#column-inbox #links #link-#{link.id}"))
      refute has_element?(view, "#column-link")
      refute has_element?(view, "#add-pill")
    end

    test "counts the links already saved apart from the new ones", %{conn: conn, scope: scope} do
      saved = link_fixture(scope, "https://example.com/two")
      {:ok, _} = Library.mark_triaged(scope, saved)

      {:ok, view, _html} = live(conn, ~p"/inbox")

      paste(view, @list <> "https://nodot\n")

      assert Library.count_links(scope) == 3
      assert render(view) =~ "2 links saved · 1 already in your archive · 1 invalid"
      assert has_element?(view, "#nav-inbox .nav-count", "2")
      refute has_element?(view, "#column-inbox #links #link-#{saved.id}")
    end

    test "a list pasted in the + field is saved the same way", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> open_pill()
      |> form("#add-link-form", %{"url" => "https://example.com/a https://example.com/b"})
      |> render_submit()

      assert Library.count_links(scope) == 2
      assert render(view) =~ "2 links saved"
      refute has_element?(view, "#add-pill")
    end

    test "text with a single link saves and opens it, as before", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/all")

      paste(view, "look at this: https://example.com/only-one, and twice <https://example.com/only-one>")

      link = only_link(scope)
      assert link.url == "https://example.com/only-one"
      assert_patch(view, ~p"/inbox/l/#{link.id}")
      assert render(view) =~ "Saved."
    end

    test "only invalid links show the error in the pill", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/")

      paste(view, "https://nodot https://another-nodot")

      assert has_element?(view, "#add-pill .field-error", "That doesn't look like a link.")
      assert Library.list_links(scope, filter: :all) == []
    end

    test "too much text shows the error and saves nothing", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/")

      paste(view, String.duplicate("https://example.com/x ", 3000))

      assert has_element?(view, "#add-pill .field-error", "That doesn't look like a link.")
      assert Library.list_links(scope, filter: :all) == []
    end
  end
end
