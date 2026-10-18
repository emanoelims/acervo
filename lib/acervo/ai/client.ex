defmodule Acervo.AI.Client do
  @moduledoc """
  A structured-output model client. `Acervo.AI.Claude` calls Anthropic through
  ReqLLM; tests use `Acervo.FakeAIClient`. The client is picked by
  `config :acervo, :ai_client`.

  `opts` carries `:usage_callback`, called once per completed HTTP response,
  including responses whose object fails validation.

  The error type, its classification and the mapping from ReqLLM errors are
  shared with `Acervo.AI.Embedder`.
  """

  alias ReqLLM.Error.API

  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:total_cost) => number()
        }

  @type error ::
          :unavailable
          | {:rate_limited, retry_after_s :: pos_integer() | nil}
          | :timeout
          | {:http, 400..599}
          | :invalid_response
          | :provider_error

  @callback generate_object(model :: String.t(), ReqLLM.Context.t(), schema :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, error()}

  @transient_statuses [408, 409]

  @doc """
  A short, content-free code for an error, as stored in `ai_calls.error`.
  """
  @spec error_code(error()) :: String.t()
  def error_code({:rate_limited, _retry_after}), do: "rate_limited"
  def error_code({:http, status}), do: "http_#{status}"
  def error_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  @doc """
  Whether a failed call is worth retrying. A missing key and 4xx other than
  408 and 409 are permanent; everything else, rate limits included, is
  transient.
  """
  @spec classify(error()) :: :transient | :permanent
  def classify(:unavailable), do: :permanent
  def classify({:http, status}) when status in @transient_statuses or status >= 500, do: :transient
  def classify({:http, _status}), do: :permanent
  def classify(_reason), do: :transient

  @doc """
  Maps a ReqLLM error to `t:error/0`. Rate limits keep `retry-after` when the
  error carries headers (ReqLLM 1.28 drops them for non-2xx responses).
  """
  @spec map_error(term()) :: error()
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

  @doc """
  The token counts and cost of a ReqLLM usage map, dropping anything else and
  any negative or non-numeric value. Embedding usage may name the token counts
  `:input` and `:output`; both spellings are read.
  """
  @spec usage(map() | nil) :: usage()
  def usage(usage) when is_map(usage) do
    Map.filter(
      %{
        input_tokens: usage[:input_tokens] || usage[:input],
        output_tokens: usage[:output_tokens] || usage[:output],
        total_cost: usage[:total_cost]
      },
      fn
        {:total_cost, value} -> is_number(value) and value >= 0
        {_key, value} -> is_integer(value) and value >= 0
      end
    )
  end

  def usage(_usage), do: %{}

  @doc """
  The error's module and HTTP status, the only parts of a ReqLLM error that
  are safe to log (its `response_body` may echo the input).
  """
  @spec error_class(term()) :: {module() | :unknown, integer() | nil}
  def error_class(%{__struct__: module, status: status}) when is_integer(status), do: {module, status}
  def error_class(%{__struct__: module}), do: {module, nil}
  def error_class(_error), do: {:unknown, nil}
end
