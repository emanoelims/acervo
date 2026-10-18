defmodule Acervo.Search.QueryCacheTest do
  use ExUnit.Case, async: true

  alias Acervo.Search.QueryCache

  @ttl to_timeout(minute: 10)

  setup do
    cache = :"query_cache_#{System.unique_integer([:positive])}"
    start_supervised!({QueryCache, name: cache, max_size: 4})
    %{cache: cache}
  end

  defp vector(i), do: Pgvector.new([i * 1.0, 0.0, 0.0])

  test "returns what was put under the same key only", %{cache: cache} do
    :ok = QueryCache.put({"user-a", "model", "bees"}, vector(1), cache: cache)

    assert {:ok, vector} = QueryCache.fetch({"user-a", "model", "bees"}, cache: cache)
    assert Pgvector.to_list(vector) == [1.0, 0.0, 0.0]
    assert :miss = QueryCache.fetch({"user-b", "model", "bees"}, cache: cache)
    assert :miss = QueryCache.fetch({"user-a", "other", "bees"}, cache: cache)
    assert :miss = QueryCache.fetch({"user-a", "model", "honey"}, cache: cache)
  end

  test "an entry older than 10 minutes is a miss, and the sweep deletes it", %{cache: cache} do
    key = {"user-a", "model", "bees"}
    :ok = QueryCache.put(key, vector(1), cache: cache, now: 0)

    assert {:ok, _} = QueryCache.fetch(key, cache: cache, now: @ttl - 1)
    assert :miss = QueryCache.fetch(key, cache: cache, now: @ttl)

    :ok = QueryCache.sweep(cache, @ttl - 1)
    assert :ets.info(cache, :size) == 1
    :ok = QueryCache.sweep(cache, @ttl)
    assert :ets.info(cache, :size) == 0
  end

  test "past its size bound it drops the oldest entries", %{cache: cache} do
    for i <- 1..5, do: :ok = QueryCache.put({"user-a", "model", "q#{i}"}, vector(i), cache: cache, now: i)

    # The trim runs in the owner after the put that crossed the bound.
    :ok = QueryCache.sweep(cache, 6)

    assert :ets.info(cache, :size) == 2
    assert {:ok, _} = QueryCache.fetch({"user-a", "model", "q5"}, cache: cache, now: 6)
    assert {:ok, _} = QueryCache.fetch({"user-a", "model", "q4"}, cache: cache, now: 6)
    assert :miss = QueryCache.fetch({"user-a", "model", "q1"}, cache: cache, now: 6)
  end

  test "the application starts the shared cache" do
    assert is_pid(Process.whereis(QueryCache))
    assert :ets.info(QueryCache, :protection) == :public
  end
end
