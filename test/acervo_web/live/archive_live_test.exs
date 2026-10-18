defmodule AcervoWeb.ArchiveLiveTest do
  use AcervoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "redirects visitors to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/")
  end

  describe "signed in" do
    setup :register_and_log_in_user

    test "home shows the root column and the dock", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#columns #column-root")
      assert has_element?(view, "#nav-inbox")
      assert has_element?(view, "#nav-all")
      assert has_element?(view, "#dock #dock-home[aria-current=page]")
      refute has_element?(view, "#column-inbox")
    end

    test "the language switch returns to the current page with its query", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inbox")
      assert view |> element("#locale-option-en") |> render() =~ "return_to=%2Finbox"

      {:ok, view, _html} = live(conn, ~p"/inbox?x=1")
      assert view |> element("#locale-option-en") |> render() =~ "return_to=%2Finbox%3Fx%3D1"
    end

    test "an empty archive reads as zero, not as one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      lead = view |> element("#column-root .lead") |> render() |> String.replace(~r/\s+/, " ")
      assert lead =~ "No links · no collections."
    end

    test "inbox opens a second column with an empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inbox")
      assert has_element?(view, "#column-inbox .empty")
      assert has_element?(view, "#nav-inbox[aria-current=page]")
      assert has_element?(view, "#dock-inbox[aria-current=page]")
    end

    test "navigating from the nav patches to /all", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#nav-all") |> render_click()
      assert_patch(view, ~p"/all")
      assert has_element?(view, "#column-all")
    end

    test "/guide opens the guide next to column 1", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/guide")
      assert has_element?(view, "#column-root")
      assert has_element?(view, "#column-guide #guide-shortcuts kbd", "?")
      assert page_title(view) =~ "Guide"
    end

    test "the dock settings open the guide", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inbox")
      view |> element("#dock-guide") |> render_click()
      assert_patch(view, ~p"/guide")
      assert has_element?(view, "#column-guide")
      refute has_element?(view, "#column-inbox")
    end

    test "? opens the guide", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/all")
      view |> element("#columns") |> render_hook("open_guide", %{})
      assert_patch(view, ~p"/guide")
      assert has_element?(view, "#column-guide")
    end

    test "settings exposes appearance, language and log out", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#appearance-panel #theme-option-studio")
      assert has_element?(view, "#appearance-panel #accent-option-graphite")
      assert has_element?(view, "#appearance-panel #font-option-inter")
      assert has_element?(view, "#locale-option-en[href^='/locale/en']")
      assert has_element?(view, "#dock-log-out")
    end
  end
end
