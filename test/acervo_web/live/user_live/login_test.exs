defmodule AcervoWeb.UserLive.LoginTest do
  use AcervoWeb.ConnCase, async: true

  import Acervo.AccountsFixtures
  import Phoenix.LiveViewTest

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#login-submit")
      assert html =~ "Send link"
      assert html =~ "Create account"
      refute html =~ "assword"
    end
  end

  describe "user login - magic link" do
    test "sends magic link email when user exists", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        lv
        |> form("#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is registered"

      assert Acervo.Repo.get_by!(Acervo.Accounts.UserToken, user_id: user.id).context ==
               "login"
    end

    test "does not disclose if user is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        lv
        |> form("#login_form_magic", user: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is registered"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the create account link is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("#register-link")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/register")

      assert login_html =~ "Create account"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      refute html =~ "Create account"
      assert html =~ "Send link"
      assert has_element?(lv, ~s(#user_email[value="#{user.email}"]))
    end
  end
end
