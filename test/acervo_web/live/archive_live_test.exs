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

    test "an empty archive reads as zero, not as one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert view |> element("#column-root .lead") |> render() =~ "No links · no collections."
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
