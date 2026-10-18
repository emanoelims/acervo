defmodule AcervoWeb.UserLive.Login do
  @moduledoc false
  use AcervoWeb, :live_view

  alias Acervo.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <.form for={@form} id="login_form_magic" action={~p"/users/log-in"} phx-submit="submit_magic">
        <.input
          readonly={!!@current_scope}
          field={@form[:email]}
          type="email"
          label={gettext("Email")}
          autocomplete="username"
          spellcheck="false"
          required
          phx-mounted={JS.focus()}
        />
        <.button id="login-submit" variant="primary" class="action action-primary auth-submit">
          {gettext("Send link")}
          <.icon name="lucide-arrow-right" class="size-4" />
        </.button>
      </.form>

      <p :if={!@current_scope} class="auth-alternate">
        <.link id="register-link" navigate={~p"/users/register"} class="text-link">
          {gettext("Create account")}
        </.link>
      </p>

      <p :if={local_mail_adapter?()} class="auth-alternate">
        <.link id="dev-mailbox-link" href="/dev/mailbox" class="text-link">
          <.icon name="lucide-mail" class="size-4" /> {gettext("Mailbox")}
        </.link>
      </p>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form)}
  end

  @impl true
  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info = gettext("If your email is registered, a sign-in link is on its way.")

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:acervo, Acervo.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
