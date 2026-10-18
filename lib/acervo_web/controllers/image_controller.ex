defmodule AcervoWeb.ImageController do
  use AcervoWeb, :controller

  alias Acervo.Storage

  def show(conn, %{"id" => id}) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, image} <- Storage.fetch(conn.assigns.current_scope, uuid) do
      conn
      |> put_resp_content_type(image.content_type, nil)
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> put_resp_header("etag", ~s("#{image.sha256}"))
      |> send_resp(200, image.bytes)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end
end
