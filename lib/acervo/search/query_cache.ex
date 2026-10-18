defmodule Acervo.Search.QueryCache do
  @moduledoc """
  Recent query vectors, kept briefly in ETS so re-running a search (submit
  after the debounce, a reconnect, back and forward, returning from a result)
  makes no second embedding call.

  Keys are `{user_id, model, normalized_query}`: an entry is never shared
  between users, so one account cannot time another's queries, and vectors
  from different models never mix. Entries expire after `ttl` (10 minutes).
  A sweep every minute drops expired entries, and the table is kept within
  `max_size` (500, about 2 MB): a `put/3` that crosses it has the owner drop
  the oldest entries, down to half of it, right after.

  The owning process only sweeps; reads and writes go straight to the
  public table.
  """
  use GenServer

  @ttl to_timeout(minute: 10)
  @max_size 500
  @sweep_every to_timeout(minute: 1)

  @type key :: {Ecto.UUID.t(), String.t(), String.t()}

  @doc """
  Starts the cache. Options: `:name` (also the table's name, default this
  module), `:ttl` and `:max_size`.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  The vector cached under `key`, or `:miss` when absent or older than the
  TTL. Options: `:cache`, `:now` (milliseconds, for tests) and `:ttl`.
  """
  @spec fetch(key(), keyword()) :: {:ok, Pgvector.t()} | :miss
  def fetch(key, opts \\ []) do
    cache = Keyword.get(opts, :cache, __MODULE__)
    now = Keyword.get_lazy(opts, :now, &now/0)
    ttl = Keyword.get(opts, :ttl, @ttl)

    case :ets.lookup(cache, key) do
      [{^key, vector, inserted_at}] when now - inserted_at < ttl -> {:ok, vector}
      _ -> :miss
    end
  end

  @doc "Caches `vector` under `key`. Options: `:cache` and `:now`."
  @spec put(key(), Pgvector.t(), keyword()) :: :ok
  def put(key, %Pgvector{} = vector, opts \\ []) do
    cache = Keyword.get(opts, :cache, __MODULE__)
    :ets.insert(cache, {key, vector, Keyword.get_lazy(opts, :now, &now/0)})
    # A put follows a paid embedding call, so asking the owner to check the
    # bound each time costs nothing that matters.
    GenServer.cast(cache, :trim)
  end

  @doc false
  # Runs a sweep now and waits for it; `now` (milliseconds) is for tests.
  @spec sweep(atom(), integer()) :: :ok
  def sweep(cache \\ __MODULE__, now \\ now()), do: GenServer.call(cache, {:sweep, now})

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    :ets.new(name, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    schedule_sweep()
    {:ok, %{table: name, ttl: Keyword.get(opts, :ttl, @ttl), max_size: Keyword.get(opts, :max_size, @max_size)}}
  end

  @impl GenServer
  def handle_call({:sweep, now}, _from, state) do
    sweep_table(state, now)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast(:trim, state) do
    trim(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep_table(state, now())
    schedule_sweep()
    {:noreply, state}
  end

  defp sweep_table(%{table: table, ttl: ttl} = state, now) do
    # Entries are {key, vector, inserted_at}; delete those at or past the TTL.
    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now - ttl}], [true]}])
    trim(state)
  end

  # Over the bound: drop the oldest half.
  defp trim(%{table: table, max_size: max_size}) do
    size = :ets.info(table, :size)

    if size > max_size do
      table
      |> :ets.select([{{:"$1", :_, :"$2"}, [], [{{:"$2", :"$1"}}]}])
      |> Enum.sort()
      |> Enum.take(size - div(max_size, 2))
      |> Enum.each(fn {_inserted_at, key} -> :ets.delete(table, key) end)
    end

    :ok
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every)

  defp now, do: System.monotonic_time(:millisecond)
end
