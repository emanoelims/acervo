defmodule Acervo.AI.OpenRouterEmbedder do
  @moduledoc """
  `Acervo.AI.Embedder` for OpenRouter, through `ReqLLM.embed/3`.

  Each call makes exactly one HTTP request: ReqLLM's transport retries are off
  and Oban owns every retry. The vector is returned only when it has exactly
  the requested number of dimensions. Failures map to
  `t:Acervo.AI.Client.error/0` and are logged by error module, HTTP status and
  failure class only, never with the input text or the response body.
  """
  @behaviour Acervo.AI.Embedder

  alias Acervo.AI.Client
  alias ReqLLM.Error.API

  require Logger

  @impl Acervo.AI.Embedder
  def embed(model, text, opts) do
    {usage_callback, opts} = Keyword.pop(opts, :usage_callback, fn _usage -> :ok end)
    dimensions = Keyword.fetch!(opts, :dimensions)

    with {:ok, api_key} <- api_key(),
         :ok <- validate_model(model) do
      model
      |> ReqLLM.embed(text, request_options(api_key, opts))
      |> notify_usage(usage_callback)
      |> extract_vector(dimensions)
    end
  end

  defp api_key do
    case Application.get_env(:acervo, :openrouter)[:api_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :unavailable}
    end
  end

  defp validate_model(model) do
    case ReqLLM.Embedding.validate_model(model) do
      {:ok, _model} -> :ok
      {:error, _} -> {:error, :provider_error}
    end
  end

  defp request_options(api_key, opts) do
    # `ReqLLM.embed/3` rejects `receive_timeout` and `max_retries` at the top
    # level, so they go to Req. ReqLLM's retry step replaces `retry:` but reads
    # `max_retries` from the Req options; zero turns it off.
    http_options =
      [retry: false, max_retries: 0, receive_timeout: Keyword.get(opts, :receive_timeout, 15_000)] ++
        Application.get_env(:acervo, :embed_req_options, [])

    [api_key: api_key, dimensions: Keyword.fetch!(opts, :dimensions), return_usage: true, req_http_options: http_options] ++
      input_type(opts[:input_type])
  end

  # Voyage embeds asymmetrically: stored text as documents, searches as queries.
  defp input_type(:document), do: [provider_options: [input_type: "document"]]
  defp input_type(:query), do: [provider_options: [input_type: "query"]]
  defp input_type(nil), do: []

  defp notify_usage({:ok, %{usage: usage}} = result, callback) do
    callback.(Client.usage(usage))
    result
  end

  defp notify_usage(result, callback) do
    callback.(%{})
    result
  end

  defp extract_vector({:ok, %{embedding: vector}}, dimensions) when is_list(vector) and length(vector) == dimensions do
    if Enum.all?(vector, &is_number/1) do
      {:ok, Enum.map(vector, &(&1 * 1.0))}
    else
      invalid(dimensions)
    end
  end

  defp extract_vector({:ok, _response}, dimensions), do: invalid(dimensions)

  # ReqLLM checks the length itself when `dimensions` is given, and rejects a
  # body without `data` the same way: both are a wrong response, not HTTP.
  defp extract_vector({:error, %API.Response{status: nil}}, dimensions), do: invalid(dimensions)

  defp extract_vector({:error, error}, _dimensions) do
    reason = Client.map_error(error)
    {module, status} = Client.error_class(error)

    Logger.warning("embedding request failed: #{inspect(module)}, HTTP #{inspect(status)}, #{Client.error_code(reason)}")

    {:error, reason}
  end

  defp invalid(dimensions) do
    Logger.warning("embedding provider returned no valid #{dimensions}-dimension vector")
    {:error, :invalid_response}
  end
end
