defmodule AcervoWeb.LocaleController do
  use AcervoWeb, :controller

  alias AcervoWeb.Locale

  def update(conn, %{"locale" => locale} = params) do
    conn
    |> put_resp_cookie(Locale.cookie(), Locale.normalize(locale),
      max_age: 60 * 60 * 24 * 365,
      same_site: "Lax"
    )
    |> redirect(to: safe_path(params["return_to"]))
  end

  # Only same-origin absolute paths: rejects "//host", backslashes and newlines.
  defp safe_path("/" <> _ = path) do
    if String.starts_with?(path, "//") or String.contains?(path, ["\\", "\n", "\r"]),
      do: "/",
      else: path
  end

  defp safe_path(_), do: "/"
end
