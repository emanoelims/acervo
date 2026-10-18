defmodule AcervoWeb.UserLive.Confirmation do
  @moduledoc false
  use AcervoWeb, :live_view

  alias Acervo.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash}>
      <p id="confirmation-email" class="auth-email">{@user.email}</p>

      <.form
        :if={!@user.confirmed_at}
        for={@form}
        id="confirmation_form"
        phx-mounted={JS.focus_first()}
        phx-submit="submit"
        action={~p"/users/log-in?_action=confirmed"}
        phx-trigger-action={@trigger_submit}
      >
        <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
        <.button
          variant="primary"
          class="action action-primary auth-submit"
          name={@form[:remember_me].name}
          value="true"
          phx-disable-with={gettext("Confirming...")}
        >
          {gettext("Confirm")}
          <.icon name="lucide-arrow-right" class="size-4" />
        </.button>
      </.form>

      <.form
        :if={@user.confirmed_at}
        for={@form}
        id="login_form"
        phx-submit="submit"
        phx-mounted={JS.focus_first()}
        action={~p"/users/log-in"}
        phx-trigger-action={@trigger_submit}
      >
        <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
        <.button
          variant="primary"
          class="action action-primary auth-submit"
          name={@form[:remember_me].name}
          value="true"
          phx-disable-with={gettext("Logging in...")}
        >
          {gettext("Log in")}
          <.icon name="lucide-arrow-right" class="size-4" />
        </.button>
      </.form>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false), temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Magic link is invalid or it has expired."))
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
