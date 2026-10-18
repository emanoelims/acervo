defmodule Acervo.Accounts.UserNotifierTest do
  # Swaps the global mailer adapter, so it cannot run concurrently.
  use Acervo.DataCase, async: false

  import Acervo.AccountsFixtures
  import ExUnit.CaptureLog

  alias Acervo.Accounts.UserNotifier

  setup do
    original = Application.fetch_env!(:acervo, Acervo.Mailer)
    Application.put_env(:acervo, Acervo.Mailer, adapter: Acervo.FailingMailAdapter)
    on_exit(fn -> Application.put_env(:acervo, Acervo.Mailer, original) end)
  end

  test "logs the reason, without the link, and returns the error" do
    user = unconfirmed_user_fixture()

    log =
      capture_log(fn ->
        assert {:error, :smtp_down} =
                 UserNotifier.deliver_login_instructions(user, "https://example.com/secret-token")
      end)

    assert log =~ "Email delivery failed: :smtp_down"
    refute log =~ "secret-token"
    refute log =~ user.email
  end
end
