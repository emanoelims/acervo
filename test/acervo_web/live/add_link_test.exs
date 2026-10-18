defmodule AcervoWeb.AddLinkTest do
  use AcervoWeb.ConnCase, async: true

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
  end
end
