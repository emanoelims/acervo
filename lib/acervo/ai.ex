defmodule Acervo.AI do
  @moduledoc """
  Model calls and their cost records.

  Every call goes through `generate_object/4`, which uses the configured
  `Acervo.AI.Client` (`config :acervo, :ai_client`), or `embed/4`, which uses
  the configured `Acervo.AI.Embedder` (`config :acervo, :embedder`). Each
  records one `Acervo.AI.Call` per call, success or not. Logs carry only ids,
  the model, token counts, cost, duration and an error code, never content.

  Each call also emits `[:acervo, :ai, :call, :stop]` with `duration`
  (native units), `input_tokens`, `output_tokens` and `cost_usd` (a float,
  the estimate), and the `operation`, `model` and `status` as metadata.
  """
  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.AI.Call
  alias Acervo.AI.Client
  alias Acervo.AI.Rates
  alias Acervo.Repo

  require Logger

  @embedding_dimensions 1024

  @doc "The configured chat model, such as `\"anthropic:claude-opus-5-5\"` (Opus 5.5 by default)."
  @spec model() :: String.t()
  def model do
    Application.get_env(:acervo, :ai, [])[:model] || "anthropic:claude-opus-5-5"
  end

  @doc """
  The configured embedding model, `\"openrouter:voyageai/voyage-4-lite\"` by
  default. It must return `embedding_dimensions/0`-long vectors.
  """
  @spec embedding_model() :: String.t()
  def embedding_model do
    Application.get_env(:acervo, :embeddings, [])[:model] || "openrouter:voyageai/voyage-4-lite"
  end

  @doc "The embedding length, fixed by the `links.embedding` column type."
  @spec embedding_dimensions() :: 1024
  def embedding_dimensions, do: @embedding_dimensions

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
  def generate_object(%Scope{} = scope, %{operation: operation} = meta, context, schema) when is_binary(operation) do
    model = model()

    run_call(scope, meta, model, fn usage_callback ->
      client().generate_object(model, context, schema, usage_callback: usage_callback)
    end)
  end

  @doc """
  Embeds `text` with the configured embedding model for the scope's user,
  recording the call in `ai_calls` like `generate_object/4`. The vector has
  `embedding_dimensions/0` floats.

  `meta` names the operation (`"embed_link"` or `"embed_query"`) and the
  link, if any. `opts` takes `:input_type` (`:document` or `:query`) and
  `:receive_timeout`.
  """
  @spec embed(Scope.t(), %{operation: String.t(), link_id: Ecto.UUID.t() | nil}, String.t(), keyword()) ::
          {:ok, [float()]} | {:error, Client.error()}
  def embed(%Scope{} = scope, %{operation: operation} = meta, text, opts \\ [])
      when is_binary(operation) and is_binary(text) do
    model = embedding_model()

    embed_opts =
      opts
      |> Keyword.take([:input_type, :receive_timeout])
      |> Keyword.put(:dimensions, @embedding_dimensions)

    run_call(scope, meta, model, fn usage_callback ->
      embedder().embed(model, text, Keyword.put(embed_opts, :usage_callback, usage_callback))
    end)
  end

  defp client, do: Application.fetch_env!(:acervo, :ai_client)
  defp embedder, do: Application.fetch_env!(:acervo, :embedder)

  # Runs one model call, then records and logs it whatever its outcome.
  defp run_call(%Scope{user: user}, %{operation: operation, link_id: link_id}, model, fun) do
    ref = make_ref()
    caller = self()

    started = System.monotonic_time()
    result = fun.(fn usage -> send(caller, {ref, usage}) end)
    duration = System.monotonic_time() - started
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

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
        {:ok, _value} -> Map.put(attrs, :status, :ok)
        {:error, reason} -> Map.merge(attrs, %{status: :error, error: Client.error_code(reason)})
      end

    record(user, attrs)
    log(attrs)
    emit(attrs, duration)
    result
  end

  # For the metrics endpoint: labels are only the operation, the model and
  # the status, never the user, the link or the error.
  defp emit(attrs, duration) do
    :telemetry.execute(
      [:acervo, :ai, :call, :stop],
      %{
        duration: duration,
        input_tokens: attrs.input_tokens || 0,
        output_tokens: attrs.output_tokens || 0,
        cost_usd: if(attrs.cost_usd, do: Decimal.to_float(attrs.cost_usd), else: 0.0)
      },
      %{operation: attrs.operation, model: attrs.model, status: attrs.status}
    )
  end

  # The usage callback runs once per completed response; keep the last one.
  defp receive_usage(ref, usage \\ %{}) do
    receive do
      {^ref, usage} -> receive_usage(ref, usage)
    after
      0 -> usage
    end
  end

  # The dated estimate (`Acervo.AI.Rates`) when the model has one, else
  # ReqLLM's cost: ReqLLM rounds to $0.000001, which zeroes a short query.
  defp cost(usage, model) do
    Rates.estimate(model, usage[:input_tokens], usage[:output_tokens]) || reported_cost(usage)
  end

  defp reported_cost(%{total_cost: cost}) when is_float(cost), do: cost |> Decimal.from_float() |> Decimal.round(8)
  defp reported_cost(%{total_cost: cost}) when is_integer(cost), do: Decimal.new(cost)
  defp reported_cost(_usage), do: nil

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
