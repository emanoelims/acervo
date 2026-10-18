defmodule AcervoWeb.Metrics.Plug do
  @moduledoc """
  Serves the Prometheus text format at `GET /metrics` for the metrics port;
  every other request gets a 404. Takes the reporter's name as `:reporter`.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :reporter)

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["metrics"]} = conn, reporter) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4", nil)
    |> send_resp(200, TelemetryMetricsPrometheus.Core.scrape(reporter))
  end

  def call(conn, _reporter), do: send_resp(conn, 404, "")
end
