defmodule AcervoWeb.UserLive.RegistrationTest do
  use AcervoWeb.ConnCase, async: false

  import Acervo.AccountsFixtures
  import Phoenix.LiveViewTest

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Create account"
      assert has_element?(lv, "#login-link")
      assert has_element?(lv, "#registration-submit")
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register user" do
    test "creates account but does not log in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      {:ok, _lv, html} =
        form
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "A sign-in link was sent to #{email}."
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => user.email}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "allowlist" do
    setup do
      previous = Application.get_env(:acervo, :allowed_emails)
      Application.put_env(:acervo, :allowed_emails, ["owner@example.com"])
      on_exit(fn -> Application.put_env(:acervo, :allowed_emails, previous) end)
    end

    test "rejects emails outside the allowlist", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> form("#registration_form", user: %{"email" => "stranger@example.com"})
        |> render_submit()

      assert result =~ "is not allowed to register"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("#login-link")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Send link"
    end
  end

  describe "when the mailer fails" do
    setup do
      original = Application.fetch_env!(:acervo, Acervo.Mailer)
      Application.put_env(:acervo, Acervo.Mailer, adapter: Acervo.FailingMailAdapter)
      on_exit(fn -> Application.put_env(:acervo, Acervo.Mailer, original) end)
    end

    @tag capture_log: true
    test "keeps the account and shows an error flash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()

      {:ok, _lv, html} =
        lv
        |> form("#registration_form", user: valid_user_attributes(email: email))
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "We couldn&#39;t send the email"
      assert Acervo.Accounts.get_user_by_email(email)
    end
  end
end
