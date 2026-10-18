defmodule Acervo.Accounts.UserNotifier do
  @moduledoc false
  use Gettext, backend: AcervoWeb.Gettext

  import Swoosh.Email

  alias Acervo.Accounts.User
  alias Acervo.Mailer

  require Logger

  # Delivers the email using the application mailer. Failures are logged (the
  # reason only, never the recipient or the link) and returned to the caller.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Application.fetch_env!(:acervo, :mail_from))
      |> subject(subject)
      |> text_body(body)

    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        {:ok, email}

      {:error, reason} = error ->
        Logger.error("Email delivery failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(
      user.email,
      gettext("Confirm your new email"),
      gettext(
        """
        Hi %{email},

        Open the link below to change your email:

        %{url}

        If you didn't ask for this, you can ignore this message.
        """,
        email: user.email,
        url: url
      )
    )
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(
      user.email,
      gettext("Your sign-in link"),
      gettext(
        """
        Hi %{email},

        Open the link below to sign in:

        %{url}

        If you didn't ask for this, you can ignore this message.
        """,
        email: user.email,
        url: url
      )
    )
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(
      user.email,
      gettext("Confirm your account"),
      gettext(
        """
        Hi %{email},

        Open the link below to confirm your account:

        %{url}

        If you didn't create an account, you can ignore this message.
        """,
        email: user.email,
        url: url
      )
    )
  end
end
