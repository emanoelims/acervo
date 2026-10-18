defmodule Acervo.Metrics do
  @moduledoc """
  Periodic measurements for the metrics endpoint (`AcervoWeb.Metrics`).

  Each runs one cheap grouped count and emits a `:telemetry` event per label
  combination, zeros included, so a gauge drops back to 0 instead of keeping
  its last value. These are operator totals across every user: they carry no
  ids and are never shown in the web layer.

    * `[:acervo, :oban, :queue]` - `%{depth: n}` per `queue` and `state`
      (available, scheduled, retryable, executing).
    * `[:acervo, :links, :status | :enrichment | :embedding]` - `%{count: n}`
      per `status` of that field (`"none"` when the field is empty).
  """
  import Ecto.Query

  alias Acervo.Library.Link
  alias Acervo.Repo

  require Logger

  @queue_states ~w(available scheduled retryable executing)

  @doc "Emits the Oban queue depth gauges."
  @spec dispatch_queue_depth() :: :ok
  def dispatch_queue_depth do
    safely(:queue_depth, fn ->
      counts = queue_depth()

      queues = Enum.uniq(configured_queues() ++ Enum.map(Map.keys(counts), &elem(&1, 0)))

      for queue <- queues, state <- @queue_states do
        :telemetry.execute(
          [:acervo, :oban, :queue],
          %{depth: Map.get(counts, {queue, state}, 0)},
          %{queue: queue, state: state}
        )
      end
    end)
  end

  @doc "Jobs waiting or running, by `{queue, state}`."
  @spec queue_depth() :: %{{String.t(), String.t()} => non_neg_integer()}
  def queue_depth do
    from(j in Oban.Job,
      where: j.state in @queue_states,
      group_by: [j.queue, j.state],
      select: {{j.queue, j.state}, count()}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Emits the link totals gauges."
  @spec dispatch_link_totals() :: :ok
  def dispatch_link_totals do
    safely(:link_totals, fn ->
      totals = link_totals()

      for {field, event} <- [status: :status, enrichment_status: :enrichment, embedding_status: :embedding],
          status <- statuses(field) do
        :telemetry.execute(
          [:acervo, :links, event],
          %{count: get_in(totals, [field, status]) || 0},
          %{status: status}
        )
      end
    end)
  end

  @doc """
  Link counts per value of `status`, `enrichment_status` and
  `embedding_status`, from one grouped query. An empty field counts as
  `"none"`.
  """
  @spec link_totals() :: %{atom() => %{String.t() => non_neg_integer()}}
  def link_totals do
    rows =
      Repo.all(
        from l in Link,
          group_by: [l.status, l.enrichment_status, l.embedding_status],
          select: {l.status, l.enrichment_status, l.embedding_status, count()}
      )

    for {field, index} <- [status: 0, enrichment_status: 1, embedding_status: 2], into: %{} do
      counts =
        Enum.reduce(rows, %{}, fn row, acc ->
          Map.update(acc, label(elem(row, index)), elem(row, 3), &(&1 + elem(row, 3)))
        end)

      {field, counts}
    end
  end

  defp statuses(:status), do: Enum.map(Ecto.Enum.values(Link, :status), &label/1)
  defp statuses(field), do: ["none" | Enum.map(Ecto.Enum.values(Link, field), &label/1)]

  defp label(nil), do: "none"
  defp label(status) when is_atom(status), do: Atom.to_string(status)

  # From the config rather than the running Oban, which has no queues in tests.
  defp configured_queues do
    :acervo |> Application.fetch_env!(Oban) |> Keyword.get(:queues, []) |> Keyword.keys() |> Enum.map(&to_string/1)
  end

  # telemetry_poller drops a measurement that raises, for good, so a database
  # hiccup would stop the gauge until the next restart. Log and skip instead.
  defp safely(name, fun) do
    fun.()
    :ok
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("metrics #{name} skipped: #{inspect(error.__struct__)}")
      :ok
  end
end
