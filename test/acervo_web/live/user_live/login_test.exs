defmodule AcervoWeb.UserLive.LoginTest do
  use AcervoWeb.ConnCase, async: false

  import Acervo.AccountsFixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  setup do
    previous = Application.get_env(:acervo, :allowed_emails)
    Application.put_env(:acervo, :allowed_emails, ["owner@example.com"])

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:acervo, :allowed_emails)
      else
        Application.put_env(:acervo, :allowed_emails, previous)
      end
    end)
  end

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#login-submit")
      assert html =~ "Send link"
      refute html =~ "Create account"
      refute html =~ "assword"
    end
  end

  describe "user login - magic link" do
    test "sends magic link email when user exists", %{conn: conn} do
      user = user_fixture(email: "owner@example.com")

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

  describe "sign in creates the account" do
    test "creates the account for a new allowed email with the same message", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        lv
        |> form("#login_form_magic", user: %{email: "owner@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is registered"
      assert %Acervo.Accounts.User{} = Acervo.Accounts.get_user_by_email("owner@example.com")
      assert_email_sent(to: "owner@example.com")
    end

    test "creates nothing and sends nothing for an email outside the allowlist", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        lv
        |> form("#login_form_magic", user: %{email: "stranger@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is registered"
      assert Acervo.Accounts.get_user_by_email("stranger@example.com") == nil
      assert_no_email_sent()
    end

    test "the registration page no longer exists", %{conn: conn} do
      assert conn |> get("/users/register") |> response(404)
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture(email: "owner@example.com")
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
