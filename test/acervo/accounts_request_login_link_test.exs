defmodule Acervo.AccountsRequestLoginLinkTest do
  use Acervo.DataCase, async: false

  import Acervo.AccountsFixtures
  import Swoosh.TestAssertions

  alias Acervo.Accounts

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

  describe "request_login_link/2" do
    test "creates the account and sends the link for an unknown allowed email" do
      assert :ok = Accounts.request_login_link("owner@example.com", &"[URL]#{&1}")

      assert %Accounts.User{} = Accounts.get_user_by_email("owner@example.com")
      assert_email_sent(to: "owner@example.com")
    end

    test "does nothing for an unknown email outside the allowlist" do
      assert :ok = Accounts.request_login_link("stranger@example.com", &"[URL]#{&1}")

      assert Accounts.get_user_by_email("stranger@example.com") == nil
      assert_no_email_sent()
    end

    test "sends the link to an existing user" do
      user = user_fixture(email: "owner@example.com")
      Swoosh.TestAssertions.assert_email_sent(to: user.email)

      assert :ok = Accounts.request_login_link(user.email, &"[URL]#{&1}")

      assert_email_sent(to: user.email)
    end
  end
end
