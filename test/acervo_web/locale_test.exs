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

  test "ignores a backslash return path", %{conn: conn} do
    conn = get(conn, "/locale/en?return_to=/%5Cevil.example")
    assert redirected_to(conn) == "/"
  end

  test "ignores a return path with a newline", %{conn: conn} do
    conn = get(conn, "/locale/en?return_to=/users%0Alog-in")
    assert redirected_to(conn) == "/"
  end

  test "ignores a percent-encoded tab return path", %{conn: conn} do
    conn = get(conn, "/locale/en?return_to=/%2509evil.example")
    assert redirected_to(conn) == "/"
  end

  test "ignores a return path with a tab", %{conn: conn} do
    conn = get(conn, "/locale/en?return_to=/%09/evil.example")
    assert redirected_to(conn) == "/"
  end

  test "ignores a return path with a literal backslash", %{conn: conn} do
    conn = get(conn, "/locale/en?return_to=/%5Cevil")
    assert redirected_to(conn) == "/"
  end

  test "keeps the query string of the return path", %{conn: conn} do
    conn = get(conn, ~p"/locale/en?#{[return_to: "/inbox?x=1"]}")
    assert redirected_to(conn) == "/inbox?x=1"
  end

  test "the cookie selects English", %{conn: conn} do
    conn = conn |> put_req_cookie("acervo_locale", "en") |> get(~p"/users/log-in")
    assert conn.assigns.locale == "en"
    assert html_response(conn, 200) =~ ~s(lang="en")
  end

  test "browser responses carry a content security policy", %{conn: conn} do
    [csp] = conn |> get(~p"/users/log-in") |> get_resp_header("content-security-policy")
    assert csp =~ "default-src 'self'"
    assert csp =~ "script-src 'self'"
    assert csp =~ "frame-ancestors 'self'"
  end
end
