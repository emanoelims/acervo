defmodule Acervo.Library.Screenshots do
  @moduledoc """
  Client for the screenshot service (`infra/screenshots/`): `take/1` asks it
  for a 1200×750 JPEG of a page's first screen.

  Configured with `config :acervo, Acervo.Library.Screenshots, url: ...,
  token: ...` (from `ACERVO_SHOTS_URL` and `ACERVO_SHOTS_TOKEN`). Without
  both the feature is off: `enabled?/0` is false and `take/1` answers
  `{:error, :disabled}`.

  Each call makes one request with Req's retries off; Oban owns retries.
  Errors say whether a retry can help (`classify/1`):

    * `:busy` (503, too many captures waiting), `{:http, status}` for any
      other unexpected status and `{:transport, reason}` are transient.
    * `:rejected` (400 bad URL, 422 the page failed or answered an error),
      `:unauthorized` (401) and `:disabled` are permanent.

  Neither the token nor response bodies are ever logged.
  """

  # The service navigates for up to 20 s, then settles and encodes.
  @receive_timeout to_timeout(minute: 1)

  @type reason ::
          :disabled | :busy | :rejected | :unauthorized | {:http, pos_integer()} | {:transport, term()}

  @doc "Whether the service is configured."
  @spec enabled?() :: boolean()
  def enabled?, do: match?({:ok, _config}, config())

  @doc "Takes a screenshot of `url`, returning the JPEG's bytes."
  @spec take(String.t()) :: {:ok, binary()} | {:error, reason()}
  def take(url) when is_binary(url) do
    with {:ok, %{url: base, token: token}} <- config() do
      [
        url: String.trim_trailing(base, "/") <> "/shot",
        json: %{url: url},
        auth: {:bearer, token},
        retry: false,
        decode_body: false,
        receive_timeout: @receive_timeout
      ]
      |> Req.post(Application.get_env(:acervo, :shots_req_options, []))
      |> handle_response()
    end
  end

  @doc "Whether a retry can help after `reason`."
  @spec classify(reason()) :: :transient | :permanent
  def classify(reason) when reason in [:rejected, :unauthorized, :disabled], do: :permanent
  def classify(_reason), do: :transient

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) when is_binary(body), do: {:ok, body}
  defp handle_response({:ok, %Req.Response{status: status}}) when status in [400, 422], do: {:error, :rejected}
  defp handle_response({:ok, %Req.Response{status: 401}}), do: {:error, :unauthorized}
  defp handle_response({:ok, %Req.Response{status: 503}}), do: {:error, :busy}
  defp handle_response({:ok, %Req.Response{status: status}}), do: {:error, {:http, status}}
  defp handle_response({:error, %Req.TransportError{reason: reason}}), do: {:error, {:transport, reason}}
  defp handle_response({:error, exception}), do: {:error, {:transport, exception.__struct__}}

  defp config do
    config = Application.get_env(:acervo, __MODULE__) || []

    case {config[:url], config[:token]} do
      {url, token} when is_binary(url) and url != "" and is_binary(token) and token != "" ->
        {:ok, %{url: url, token: token}}

      _ ->
        {:error, :disabled}
    end
  end
end
