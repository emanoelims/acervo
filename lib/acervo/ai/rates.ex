defmodule Acervo.AI.Rates do
  @moduledoc """
  Dated cost estimates in USD per million tokens, keyed by the full model
  spec: Claude at Anthropic's published standard (global routing) rates of
  2026-10-17, and voyage-4-lite at OpenRouter's listed rate of 2026-10-18.

  ReqLLM 1.28 prices Anthropic responses only when the caller names the
  inference geography, so its `usage.total_cost` is nil there. It does price
  embeddings, but rounds to $0.000001, which reads as zero for a short query.
  `Acervo.AI` therefore prefers this table and falls back to ReqLLM's cost
  for models it does not list. Acervo does not use prompt caching, and
  reasoning tokens are already counted as output. Update the table and its
  date when prices change.
  """

  # {input, output} per million tokens; Haiku's long-context tier applies to
  # the whole request above 100k prompt tokens.
  @long_context 100_000

  @doc "The estimated USD cost of a call, or nil for an unknown model or missing tokens."
  @spec estimate(String.t(), non_neg_integer() | nil, non_neg_integer() | nil) :: Decimal.t() | nil
  def estimate(model, input_tokens, output_tokens)
      when is_integer(input_tokens) and input_tokens >= 0 and is_integer(output_tokens) and output_tokens >= 0 do
    case rates(model, input_tokens) do
      {input_rate, output_rate} ->
        input_tokens
        |> Decimal.mult(input_rate)
        |> Decimal.add(Decimal.mult(output_tokens, output_rate))
        |> Decimal.div(1_000_000)
        |> Decimal.round(8)

      nil ->
        nil
    end
  end

  def estimate(_model, _input_tokens, _output_tokens), do: nil

  defp rates("anthropic:claude-opus-5-5", _input), do: {Decimal.new("4"), Decimal.new("20")}
  defp rates("anthropic:claude-sonnet-5-5", _input), do: {Decimal.new("2"), Decimal.new("10")}

  defp rates("anthropic:claude-haiku-5-5", input) when input > @long_context, do: {Decimal.new("0.5"), Decimal.new("2.5")}

  defp rates("anthropic:claude-haiku-5-5", _input), do: {Decimal.new("0.1"), Decimal.new("0.5")}
  defp rates("openrouter:voyageai/voyage-4-lite", _input), do: {Decimal.new("0.02"), Decimal.new("0")}
  defp rates(_model, _input), do: nil
end
