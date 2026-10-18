defmodule AcervoWeb.RegistrationLocaleTest do
  use AcervoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous = Application.get_env(:acervo, :allowed_emails)
    Application.put_env(:acervo, :allowed_emails, ["owner@example.com"])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:acervo, :allowed_emails, previous),
        else: Application.delete_env(:acervo, :allowed_emails)
    end)
  end

  test "shows the allowlist error in Portuguese by default" do
    {:ok, lv, _html} = live(build_conn(), ~p"/users/register")

    html =
      lv
      |> form("#registration_form", user: %{email: "stranger@example.com"})
      |> render_submit()

    assert html =~ "não está autorizado a se cadastrar"
    refute html =~ "is not allowed to register"
  end
end
