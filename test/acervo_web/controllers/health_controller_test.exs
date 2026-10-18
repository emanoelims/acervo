defmodule AcervoWeb.HealthControllerTest do
  use AcervoWeb.ConnCase, async: true

  test "reports ok when the database answers", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get(~p"/health") |> json_response(200)
  end
end
