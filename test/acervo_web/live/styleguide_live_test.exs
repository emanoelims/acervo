defmodule AcervoWeb.StyleguideLiveTest do
  use AcervoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders tokens, primitives and domain components without a user", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/dev/styleguide")

    assert html =~ "Styleguide"

    for id <-
          ~w(sg-colors sg-type sg-icons sg-buttons sg-chips sg-nav sg-column sg-popover sg-inputs sg-float sg-drop sg-flash sg-empty sg-app sg-home) do
      assert has_element?(view, "##{id}")
    end

    # One card per kind, the inbox bar, the open link and the reader view.
    for kind <- ~w(pending video image text) do
      assert has_element?(view, "#sg-column-all a.card.card-#{kind}, #sg-column-all a.card.#{kind}")
    end

    assert has_element?(view, "#sg-inbox-suggested .ibar .chip.ai")
    assert has_element?(view, "#sg-inbox-reading .chip.is-waiting")
    assert has_element?(view, "#sg-column-link #link-detail")
    assert has_element?(view, "#sg-column-web #web-reader")
    assert has_element?(view, "#dock")

    # The home column: compact cards of every kind and "See all".
    for kind <- ~w(pending video image text) do
      assert has_element?(view, "#sg-home-design a.card-compact.card-#{kind}")
    end

    assert has_element?(view, "#sg-home-design .column-count", "24")
    assert has_element?(view, "#sg-home-design .see-all")
  end

  test "images come from the examples, not from /images", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/dev/styleguide")

    refute html =~ ~s(src="/images/)
    assert html =~ ~s(src="data:image/svg+xml;base64,)
  end

  test "opening a card shows it in the link column", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dev/styleguide")

    view |> element("#sg-card-video") |> render_click()

    assert_patch(view, ~p"/dev/styleguide?link=video")
    assert has_element?(view, "#sg-card-video.is-selected")
    assert view |> element("#sg-column-link .column-title") |> render() =~ "Grids, from the ground up"
  end

  test "the theme switch presses the chosen theme", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dev/styleguide")

    view |> element("#sg-theme-ink") |> render_click()

    assert has_element?(view, "#sg-theme-ink[aria-pressed=true]")
    assert has_element?(view, "#sg-theme-studio[aria-pressed=false]")
  end

  test "the dock opens the pills and other clicks show their event", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dev/styleguide")

    view |> element("#dock-add") |> render_click()
    assert has_element?(view, "#add-pill")

    view |> element("#dock-search") |> render_click()
    assert has_element?(view, "#search-pill")
    refute has_element?(view, "#add-pill")

    view |> element("#done-00000000-0000-7000-8000-000000000006") |> render_click()
    assert render(view) =~ "Event: finish"
  end
end
