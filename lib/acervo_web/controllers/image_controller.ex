defmodule AcervoWeb.ImageController do
  use AcervoWeb, :controller

  alias Acervo.Storage

  def show(conn, %{"id" => id}) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, image} <- Storage.fetch(conn.assigns.current_scope, uuid) do
      etag = ~s("#{image.sha256}")

      conn =
        conn
        |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
        |> put_resp_header("etag", etag)

      if etag in get_req_header(conn, "if-none-match") do
        send_resp(conn, 304, "")
      else
        conn
        |> put_resp_content_type(image.content_type, nil)
        |> send_resp(200, image.bytes)
      end
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end
end
