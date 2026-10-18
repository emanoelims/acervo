defmodule AcervoWeb.LocaleTest do
  use AcervoWeb.ConnCase, async: true

  alias AcervoWeb.Locale

  test "normalize/1 falls back to pt_BR" do
    assert Locale.normalize("en") == "en"
    assert Locale.normalize("xx") == "pt_BR"
    assert Locale.normalize(nil) == "pt_BR"
  end

  test "defaults to Portuguese" do
    conn = get(build_conn(), ~p"/users/log-in")
    assert conn.assigns.locale == "pt_BR"
    html = html_response(conn, 200)
    assert html =~ ~s(lang="pt-BR")
    assert html =~ "Enviar link de acesso"
  end

  test "switching sets a cookie and redirects to a local path", %{conn: conn} do
    conn = get(conn, ~p"/locale/en?return_to=/users/log-in")
    assert redirected_to(conn) == "/users/log-in"
    assert conn.resp_cookies["acervo_locale"].value == "en"
  end

  test "ignores external return paths", %{conn: conn} do
    conn = get(conn, ~p"/locale/en?return_to=//evil.example")
    assert redirected_to(conn) == "/"
  end

  test "the cookie selects English", %{conn: conn} do
    conn = conn |> put_req_cookie("acervo_locale", "en") |> get(~p"/users/log-in")
    assert conn.assigns.locale == "en"
    assert html_response(conn, 200) =~ ~s(lang="en")
  end
end
