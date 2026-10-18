defmodule Acervo.AI.Client do
  @moduledoc """
  A structured-output model client. `Acervo.AI.Claude` calls Anthropic through
  ReqLLM; tests use `Acervo.FakeAIClient`. The client is picked by
  `config :acervo, :ai_client`.

  `opts` carries `:usage_callback`, called once per completed HTTP response,
  including responses whose object fails validation.
  """

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

  @doc """
  A short, content-free code for an error, as stored in `ai_calls.error`.
  """
  @spec error_code(error()) :: String.t()
  def error_code({:rate_limited, _retry_after}), do: "rate_limited"
  def error_code({:http, status}), do: "http_#{status}"
  def error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
end
