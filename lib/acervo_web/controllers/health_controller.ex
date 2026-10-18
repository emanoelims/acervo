defmodule AcervoWeb.HealthController do
  use AcervoWeb, :controller

  @doc "Reports readiness; answers 503 when the database does not respond."
  def show(conn, _params) do
    case Acervo.Repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> json(conn, %{status: "ok"})
      {:error, _} -> conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
    end
  end
end
