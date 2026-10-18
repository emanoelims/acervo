defmodule Acervo.AI.Claude do
  @moduledoc """
  `Acervo.AI.Client` for Anthropic, through `ReqLLM.generate_object/4`.

  Each call makes exactly one HTTP request: ReqLLM's transport retries are off
  and Oban owns every retry. The returned object has string keys and has been
  validated against the schema. Failures map to `t:Acervo.AI.Client.error/0`
  and are logged by error module, HTTP status and failure class only, never
  with request or response content.
  """
  @behaviour Acervo.AI.Client

  alias Acervo.AI.Client
  alias ReqLLM.Error.API

  require Logger

  @impl Client
  def generate_object(model, context, schema, opts) do
    {usage_callback, opts} = Keyword.pop(opts, :usage_callback, fn _usage -> :ok end)

    with {:ok, api_key} <- api_key(),
         {:ok, resolved} <- resolve_model(model) do
      resolved
      |> ReqLLM.generate_object(context, schema, request_options(api_key, opts))
      |> notify_usage(usage_callback)
      |> extract_object(schema)
    end
  end

  defp api_key do
    case Application.get_env(:acervo, :anthropic)[:api_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :unavailable}
    end
  end

  defp resolve_model(model) do
    case ReqLLM.model(model) do
      {:ok, _model} = resolved -> resolved
      {:error, _} -> {:error, :provider_error}
    end
  end

  defp request_options(api_key, opts) do
    Keyword.merge(
      [
        api_key: api_key,
        # Haiku 5.5 thinks by default, and thinking counts against max_tokens.
        max_tokens: 4_000,
        reasoning_effort: :low,
        receive_timeout: 60_000,
        # ReqLLM's own retry step replaces Req's `retry:`; zero turns it off.
        max_retries: 0,
        req_http_options: [retry: false] ++ Application.get_env(:acervo, :ai_req_options, [])
      ],
      opts
    )
  end

  defp notify_usage({:ok, response} = result, callback) do
    callback.(usage(response.usage))
    result
  end

  defp notify_usage(result, callback) do
    callback.(%{})
    result
  end

  @doc false
  @spec usage(map() | nil) :: Client.usage()
  def usage(usage) when is_map(usage) do
    usage
    |> Map.take([:input_tokens, :output_tokens, :total_cost])
    |> Map.filter(fn
      {:total_cost, value} -> is_number(value) and value >= 0
      {_key, value} -> is_integer(value) and value >= 0
    end)
  end

  def usage(_usage), do: %{}

  defp extract_object({:ok, response}, schema) do
    with {:ok, object} when is_map(object) <- ReqLLM.Response.unwrap_object(response),
         object = Jason.decode!(Jason.encode!(object)),
         {:ok, _} <- ReqLLM.Schema.validate(object, schema) do
      {:ok, object}
    else
      _ ->
        Logger.warning("AI provider returned no valid object: finish_reason=#{inspect(response.finish_reason)}")
        {:error, :invalid_response}
    end
  end

  defp extract_object({:error, error}, _schema) do
    reason = map_error(error)
    {module, status} = error_class(error)

    Logger.warning(
      "AI provider request failed: #{inspect(module)}, HTTP #{inspect(status)}, #{Client.error_code(reason)}"
    )

    {:error, reason}
  end

  @doc false
  @spec map_error(term()) :: Client.error()
  def map_error(%API.Request{status: 429, headers: headers}), do: {:rate_limited, retry_after(headers)}
  def map_error(%{status: 408}), do: :timeout
  def map_error(%{status: status}) when is_integer(status) and status in 400..599, do: {:http, status}
  def map_error(%API.Timeout{}), do: :timeout
  def map_error(%Req.TransportError{reason: :timeout}), do: :timeout
  def map_error(%{cause: cause}) when is_exception(cause), do: map_error_cause(cause)
  def map_error(_error), do: :provider_error

  defp map_error_cause(%API.Timeout{}), do: :timeout
  defp map_error_cause(%Req.TransportError{reason: :timeout}), do: :timeout
  defp map_error_cause(_cause), do: :provider_error

  defp retry_after(headers) do
    value =
      case headers do
        %{} -> headers |> Map.get("retry-after") |> List.wrap() |> List.first()
        list when is_list(list) -> list |> List.keyfind("retry-after", 0, {nil, nil}) |> elem(1)
        _ -> nil
      end

    case value && Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds > 0 -> seconds
      _ -> nil
    end
  end

  defp error_class(%{__struct__: module, status: status}) when is_integer(status), do: {module, status}
  defp error_class(%{__struct__: module}), do: {module, nil}
  defp error_class(_error), do: {:unknown, nil}
end
