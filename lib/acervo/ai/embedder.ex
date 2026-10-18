defmodule Acervo.AI.Embedder do
  @moduledoc """
  A text embedding client. `Acervo.AI.OpenRouterEmbedder` calls OpenRouter
  through ReqLLM; tests use `Acervo.FakeEmbedder`. The embedder is picked by
  `config :acervo, :embedder`, and `Acervo.AI.embed/4` is its only caller.

  `opts`:

    * `:dimensions` - the vector length to request and to require.
    * `:input_type` - `:document` for stored text, `:query` for searches.
    * `:receive_timeout` - in milliseconds.
    * `:usage_callback` - called once per completed HTTP response, including
      one whose vector is rejected.
  """

  @callback embed(model :: String.t(), text :: String.t(), opts :: keyword()) ::
              {:ok, [float()]} | {:error, Acervo.AI.Client.error()}
end
