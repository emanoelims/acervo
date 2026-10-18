defmodule Acervo.AI do
  @moduledoc """
  Model calls and their cost records.

  Every call goes through `generate_object/4`, which uses the configured
  `Acervo.AI.Client` (`config :acervo, :ai_client`) and records one
  `Acervo.AI.Call` per call, success or not. Logs carry only ids, the model,
  token counts, cost, duration and an error code, never content.
  """
  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.AI.Call
  alias Acervo.AI.Client
  alias Acervo.AI.Rates
  alias Acervo.Repo

  require Logger

  @doc "The configured chat model, such as `\"anthropic:claude-opus-5-5\"` (Opus 5.5 by default)."
  @spec model() :: String.t()
  def model do
    Application.get_env(:acervo, :ai, [])[:model] || "anthropic:claude-opus-5-5"
  end

  @doc """
  Generates an object matching `schema` for the scope's user, recording the
  call's tokens, cost and duration in `ai_calls`.

  `meta` names the operation (such as `"enrich_link"`) and the link the call
  is about, if any.
  """
  @spec generate_object(
          Scope.t(),
          %{operation: String.t(), link_id: Ecto.UUID.t() | nil},
          ReqLLM.Context.t(),
          map()
        ) :: {:ok, map()} | {:error, Client.error()}
  def generate_object(%Scope{user: user}, %{operation: operation, link_id: link_id}, context, schema)
      when is_binary(operation) do
    model = model()
    ref = make_ref()
    caller = self()
    usage_callback = fn usage -> send(caller, {ref, usage}) end

    started = System.monotonic_time()
    result = client().generate_object(model, context, schema, usage_callback: usage_callback)
    duration_ms = System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    usage = receive_usage(ref)

    attrs = %{
      operation: operation,
      model: model,
      link_id: link_id,
      input_tokens: usage[:input_tokens],
      output_tokens: usage[:output_tokens],
      cost_usd: cost(usage, model),
      duration_ms: duration_ms
    }

    attrs =
      case result do
        {:ok, _object} -> Map.put(attrs, :status, :ok)
        {:error, reason} -> Map.merge(attrs, %{status: :error, error: Client.error_code(reason)})
      end

    record(user, attrs)
    log(attrs)
    result
  end

  defp client, do: Application.fetch_env!(:acervo, :ai_client)

  # The usage callback runs once per completed response; keep the last one.
  defp receive_usage(ref, usage \\ %{}) do
    receive do
      {^ref, usage} -> receive_usage(ref, usage)
    after
      0 -> usage
    end
  end

  # ReqLLM's cost when it has one, else the dated estimate (`Acervo.AI.Rates`).
  defp cost(%{total_cost: cost}, _model) when is_float(cost), do: cost |> Decimal.from_float() |> Decimal.round(8)
  defp cost(%{total_cost: cost}, _model) when is_integer(cost), do: Decimal.new(cost)
  defp cost(usage, model), do: Rates.estimate(model, usage[:input_tokens], usage[:output_tokens])

  defp record(user, attrs) do
    case %Call{user_id: user.id} |> Call.changeset(attrs) |> Repo.insert() do
      {:ok, _call} ->
        :ok

      # The link was deleted during the call: keep the cost record without it.
      {:error, %Ecto.Changeset{errors: [link_id: _]}} ->
        record(user, %{attrs | link_id: nil})

      {:error, changeset} ->
        Logger.error("ai call record rejected: #{inspect(Keyword.keys(changeset.errors))}")
    end
  end

  defp log(attrs) do
    Logger.info(
      "ai #{attrs.operation} link=#{attrs.link_id} model=#{attrs.model} status=#{attrs[:error] || attrs.status} " <>
        "in=#{attrs.input_tokens} out=#{attrs.output_tokens} cost=#{attrs.cost_usd} ms=#{attrs.duration_ms}"
    )
  end

  @doc """
  Daily totals of model calls over the last `days` days, oldest first.

  This is an operator report across every user, not scoped to one: call it
  only from `Acervo.Release`, never from the web layer. `cost_usd` is nil for
  a day whose calls all lack a cost.
  """
  @spec cost_summary(pos_integer()) :: [
          %{
            day: Date.t(),
            calls: non_neg_integer(),
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            cost_usd: Decimal.t() | nil
          }
        ]
  def cost_summary(days) when is_integer(days) and days > 0 do
    since = DateTime.utc_now() |> DateTime.shift(day: -days) |> DateTime.truncate(:second)

    Repo.all(
      from c in Call,
        where: c.inserted_at >= ^since,
        group_by: selected_as(:day),
        order_by: selected_as(:day),
        select: %{
          day: selected_as(type(fragment("?::date", c.inserted_at), :date), :day),
          calls: count(c.id),
          input_tokens: type(coalesce(sum(c.input_tokens), 0), :integer),
          output_tokens: type(coalesce(sum(c.output_tokens), 0), :integer),
          cost_usd: sum(c.cost_usd)
        }
    )
  end
end
