defmodule Acervo.FakeAIClient do
  @moduledoc """
  The `Acervo.AI.Client` used in tests. A test stubs the result with
  `stub/1`; without a stub, a call raises, so no test can reach the network.

  The stub lives in the test process and is found from processes it started
  through `$callers` (Oban's `perform_job/2` runs inline, in the test process).
  Every call reports a fixed usage through `:usage_callback`.
  """
  @behaviour Acervo.AI.Client

  @stub_key {__MODULE__, :stub}
  @context_key {__MODULE__, :last_context}

  @usage %{input_tokens: 1200, output_tokens: 80, total_cost: 0.0002}

  @doc "The usage every call reports."
  def usage, do: @usage

  @doc """
  Stores `fun.(model, context, schema, opts)` as the result of the next calls.
  `usage:` replaces the reported usage (`%{}` for a response without usage).
  """
  def stub(fun, opts \\ []) when is_function(fun, 4), do: Process.put(@stub_key, {fun, Keyword.get(opts, :usage, @usage)})

  @doc "The last `ReqLLM.Context` received in this process."
  def last_context, do: Process.get(@context_key)

  @impl Acervo.AI.Client
  def generate_object(model, context, schema, opts) do
    {fun, usage} = find_stub() || raise "no AI stub"
    Process.put(@context_key, context)
    result = fun.(model, context, schema, opts)

    if callback = opts[:usage_callback], do: callback.(usage)
    result
  end

  defp find_stub do
    Process.get(@stub_key) ||
      :"$callers"
      |> Process.get([])
      |> Enum.find_value(fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dictionary} -> dictionary |> List.keyfind(@stub_key, 0, {nil, nil}) |> elem(1)
          nil -> nil
        end
      end)
  end
end
