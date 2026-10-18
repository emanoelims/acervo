defmodule AcervoWeb.LocaleController do
  use AcervoWeb, :controller

  alias AcervoWeb.Locale

  @secure_cookies Application.compile_env(:acervo, :secure_cookies, false)

  def update(conn, %{"locale" => locale} = params) do
    conn
    |> put_resp_cookie(Locale.cookie(), Locale.normalize(locale),
      max_age: 60 * 60 * 24 * 365,
      same_site: "Lax",
      secure: @secure_cookies
    )
    |> redirect(to: safe_path(params["return_to"]))
  end

  # Only same-origin local paths (a query string is fine), validated by Phoenix.
  defp safe_path(path) when is_binary(path) do
    if Phoenix.URL.classify_local_path(path) == :ok, do: path, else: "/"
  end

  defp safe_path(_), do: "/"
end
