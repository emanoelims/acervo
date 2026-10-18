defmodule Acervo.FakeEmbedder do
  @moduledoc """
  The `Acervo.AI.Embedder` used in tests. Without a stub it hashes the text
  into a deterministic, L2-normalized 1024-dimension vector, so tests that
  only need some vector (LiveView search tests, workers) work unstubbed and
  never reach the network.

  A test stubs the result with `stub/2`. The stub lives in the test process
  and is found from processes it started through `$callers`, as in
  `Acervo.FakeAIClient`. `axis/2` and `blend/1` build vectors whose cosine
  ordering a test designs by construction. Every call reports a fixed usage
  through `:usage_callback` and is counted for the test process (`calls/0`).
  """
  @behaviour Acervo.AI.Embedder

  @stub_key {__MODULE__, :stub}
  @dimensions 1024

  @usage %{input_tokens: 12, output_tokens: 0, total_cost: 0.00000024}

  @doc "The usage every call reports."
  def usage, do: @usage

  @doc """
  Stores `fun.(model, text, opts)` as the result of the next calls.
  `usage:` replaces the reported usage (`%{}` for a response without usage).
  """
  def stub(fun, opts \\ []) when is_function(fun, 3), do: Process.put(@stub_key, {fun, Keyword.get(opts, :usage, @usage)})

  @doc "The number of calls made by the test process and the processes it started."
  def calls do
    case :ets.lookup(table(), self()) do
      [{_pid, count}] -> count
      [] -> 0
    end
  end

  @doc "The default vector for `text`: seeded by its SHA-256, unit length."
  def vector(text) when is_binary(text) do
    <<seed::256>> = :crypto.hash(:sha256, text)

    {floats, _state} =
      Enum.map_reduce(1..@dimensions, :rand.seed_s(:exsss, seed), fn _i, state ->
        {float, state} = :rand.uniform_s(state)
        {float * 2 - 1, state}
      end)

    normalize(floats)
  end

  @doc "A vector with `weight` on dimension `i` (0-based) and zero elsewhere."
  def axis(i, weight \\ 1.0) when is_integer(i) and i >= 0 and i < @dimensions do
    0.0 |> List.duplicate(@dimensions) |> List.replace_at(i, weight * 1.0)
  end

  @doc "The normalized sum of weighted axes, such as `blend([{0, 1.0}, {1, 0.5}])`."
  def blend(weights) when is_list(weights) and weights != [] do
    weights
    |> Enum.reduce(List.duplicate(0.0, @dimensions), fn {i, weight}, acc ->
      List.update_at(acc, i, &(&1 + weight))
    end)
    |> normalize()
  end

  @impl Acervo.AI.Embedder
  def embed(model, text, opts) do
    count_call()
    {fun, usage} = find_stub() || {fn _model, text, _opts -> {:ok, vector(text)} end, @usage}
    result = fun.(model, text, opts)

    if callback = opts[:usage_callback], do: callback.(usage)
    result
  end

  defp normalize(floats) do
    norm = :math.sqrt(Enum.reduce(floats, 0.0, &(&1 * &1 + &2)))
    Enum.map(floats, &(&1 / norm))
  end

  defp find_stub do
    Process.get(@stub_key) ||
      Enum.find_value(callers(), fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dictionary} -> dictionary |> List.keyfind(@stub_key, 0, {nil, nil}) |> elem(1)
          nil -> nil
        end
      end)
  end

  # Counted for the test process: the outermost caller, or this process.
  defp count_call do
    owner = List.last(callers()) || self()
    :ets.update_counter(table(), owner, 1, {owner, 0})
  end

  defp callers, do: Process.get(:"$callers", [])

  # A public table owned by the test runner (started in test_helper.exs).
  defp table, do: __MODULE__

  @doc false
  def start do
    :ets.new(__MODULE__, [:named_table, :public, :set, write_concurrency: true])
    :ok
  end
end
