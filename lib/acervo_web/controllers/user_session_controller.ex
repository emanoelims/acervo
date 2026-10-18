defmodule AcervoWeb.UserSessionController do
  use AcervoWeb, :controller

  alias Acervo.Accounts
  alias AcervoWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, gettext("Welcome to Acervo."))
  end

  def create(conn, params) do
    create(conn, params, gettext("Welcome back."))
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, gettext("The link is invalid or it has expired."))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp create(conn, _params, _info) do
    conn
    |> put_flash(:error, gettext("The link is invalid or it has expired."))
    |> redirect(to: ~p"/users/log-in")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("Logged out."))
    |> UserAuth.log_out_user()
  end
end
