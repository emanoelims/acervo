defmodule Acervo.Search do
  @moduledoc """
  Hybrid search over the scope's links: full text and vectors, merged with
  Reciprocal Rank Fusion.

    * **Text:** `links.search_tsv` against a prefix OR query built by
      `text_terms/1` (`elixir:* | interop:*`), ranked by `ts_rank_cd`, top 50.
      Words under three letters and common Portuguese and English function
      words are ignored, and a link must match at least half of what is
      left, so a natural phrase ("aquele post sobre interop de javascript")
      still finds its link without loose one-word hits. Terms keep only letters and digits, so
      the tsquery can't hold an operator from the input.
    * **Vector:** the query embedded with `input_type: :query`, top 50 by
      cosine distance among links embedded with the configured model (a
      vector from another model is never compared). Hits farther than
      `max_distance` are dropped, so a query that matches nothing finds
      nothing; text hits are always kept.
    * **Fusion:** `score = Σ 1 / (60 + rank)` over both lists, ties broken by
      the newer link.

  The query vector comes from `Acervo.Search.QueryCache` when the user ran
  the same query in the last 10 minutes. Otherwise it is embedded in a task
  while the text query runs. When that takes longer than `embed_timeout`
  (3 s), or fails, the search returns the text results flagged `partial`.
  The late task is not killed: it finishes within its own
  `query_receive_timeout`, records its cost and fills the cache.

  Every query is scoped to the user, and to one of the user's collections
  when asked. Every user value reaches Postgres as a bound parameter. Logs
  carry counts, timings and flags, never the query.

  Each search (of at least 2 characters, with valid filters) emits
  `[:acervo, :search, :stop]` with `duration` (native units) and `results`,
  and the `partial`, `cached` and `scoped` (a collection or source filter)
  flags as metadata, never the query.
  """
  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.AI
  alias Acervo.Collections.Collection
  alias Acervo.Collections.CollectionLink
  alias Acervo.Library
  alias Acervo.Library.Link
  alias Acervo.Repo
  alias Acervo.Search.QueryCache

  require Logger

  # Words that say nothing about a link; a natural phrase is full of them.
  @stopwords MapSet.new(~w(
    aquele aquela aqueles aquelas aquilo este esta estes estas isto esse essa esses essas isso
    sobre para pela pelo pelas pelos com sem uma uns umas que qual quais quando onde como
    mas mais muito muita das dos nas nos num numa até entre depois antes ainda também
    ele ela eles elas meu minha seu sua nosso nossa vou foi era ser ter tem tinha
    post posts link links coisa coisas algo alguma algum
    the and for with from that this those these about into over what which when where how
    was were are its his her their our your you any some thing things
  ))

  @rrf_k 60
  @list_size 50
  @default_limit 60
  @max_query_length 200
  @min_query_length 2
  @sources Ecto.Enum.values(Link, :source)
  @control ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}]/u

  @type result :: %{links: [Link.t()], partial: boolean()}
  @type ranked :: [{Ecto.UUID.t(), DateTime.t()}]

  @doc """
  Searches the scope's links for `query`.

  Options:
    * `:collection_id` - only links in this collection, which must be the
      scope's (checked in the query; another user's yields nothing);
    * `:source` - only links from this source, such as `:youtube`;
    * `:limit` - at most this many links (default 60).

  A query shorter than 2 characters returns no links, for the caller to show
  recent ones instead.
  """
  @spec search(Scope.t(), String.t(), keyword()) :: result()
  def search(%Scope{} = scope, query, opts \\ []) when is_binary(query) do
    opts = Keyword.validate!(opts, [:collection_id, :source, limit: @default_limit])
    query = normalize_query(query)

    cond do
      String.length(query) < @min_query_length -> %{links: [], partial: false}
      not valid_filters?(opts) -> %{links: [], partial: false}
      true -> run(scope, query, opts)
    end
  end

  defp valid_filters?(opts) do
    valid_collection? =
      case opts[:collection_id] do
        nil -> true
        id -> match?({:ok, _}, Ecto.UUID.cast(id))
      end

    source = opts[:source]
    valid_collection? and (is_nil(source) or source in @sources)
  end

  defp run(scope, query, opts) do
    started_native = System.monotonic_time()
    started = System.convert_time_unit(started_native, :native, :millisecond)
    deadline = started + config(:embed_timeout, 3_000)

    pending = start_query_vector(scope, query)
    text = text_ranks(scope, query, opts)

    {vector, partial?, cached?} =
      case await_query_vector(pending, deadline) do
        {:ok, query_vector, cached?} -> {vector_ranks(scope, query_vector, with_cutoff(opts)), false, cached?}
        :error -> {[], true, false}
      end

    links =
      text
      |> fuse(vector, @rrf_k)
      |> Enum.take(opts[:limit])
      |> then(&Library.list_links_by_ids(scope, &1))

    Logger.info(
      "search ms=#{System.monotonic_time(:millisecond) - started} text=#{length(text)} " <>
        "vector=#{if partial?, do: "-", else: length(vector)} partial=#{partial?} cached=#{cached?}"
    )

    :telemetry.execute(
      [:acervo, :search, :stop],
      %{duration: System.monotonic_time() - started_native, results: length(links)},
      %{partial: partial?, cached: cached?, scoped: not is_nil(opts[:collection_id] || opts[:source])}
    )

    %{links: links, partial: partial?}
  end

  # A cached vector is used at once; otherwise the embedding starts in an
  # unlinked task so the text query runs meanwhile.
  defp start_query_vector(scope, query) do
    case QueryCache.fetch(cache_key(scope, query)) do
      {:ok, vector} -> {:cached, vector}
      :miss -> {:task, Task.Supervisor.async_nolink(Acervo.TaskSupervisor, fn -> query_vector(scope, query) end)}
    end
  end

  defp await_query_vector({:cached, vector}, _deadline), do: {:ok, vector, true}

  defp await_query_vector({:task, task}, deadline) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, wait) || Task.ignore(task) do
      {:ok, {:ok, _vector, _cached?} = result} -> result
      # Timed out (the task keeps running, unlinked and bounded by its own
      # receive timeout), failed, or crashed: text only.
      _other -> :error
    end
  end

  @doc false
  # The query's vector from the cache, or embedded (and cached) with the
  # search's own receive timeout rather than the embedder's 15 s default.
  # The call is recorded in `ai_calls` as `embed_query`.
  @spec query_vector(Scope.t(), String.t()) :: {:ok, Pgvector.t(), cached? :: boolean()} | {:error, term()}
  def query_vector(%Scope{} = scope, query) do
    key = cache_key(scope, query)

    case QueryCache.fetch(key) do
      {:ok, vector} -> {:ok, vector, true}
      :miss -> embed_query(scope, key)
    end
  end

  defp embed_query(scope, {_user_id, _model, query} = key) do
    opts = [input_type: :query, receive_timeout: config(:query_receive_timeout, 10_000)]

    case AI.embed(scope, %{operation: "embed_query", link_id: nil}, query, opts) do
      {:ok, floats} ->
        vector = Pgvector.new(floats)
        QueryCache.put(key, vector)
        {:ok, vector, false}

      {:error, _reason} = error ->
        error
    end
  end

  defp with_cutoff(opts), do: Keyword.put(opts, :max_distance, config(:max_distance, nil))

  defp cache_key(%Scope{user: user}, query), do: {user.id, AI.embedding_model(), query}

  defp config(key, default), do: Keyword.get(Application.get_env(:acervo, :search, []), key, default)

  @doc false
  # NUL and other control characters out, whitespace collapsed, at most 200
  # characters (cut on a grapheme boundary).
  @spec normalize_query(String.t()) :: String.t()
  def normalize_query(query) when is_binary(query) do
    query
    |> String.replace_invalid()
    |> String.replace(@control, " ")
    |> String.split()
    |> Enum.join(" ")
    |> String.slice(0, @max_query_length)
    |> String.trim()
  end

  @doc false
  # The top 50 full-text matches, best first. `links.search_tsv` is a
  # generated column outside the `Link` schema, hence the schemaless source.
  @spec text_ranks(Scope.t(), String.t(), keyword()) :: ranked()
  def text_ranks(%Scope{user: user}, query, opts \\ []) do
    case text_terms(query) do
      [] -> []
      terms -> ranked_text(user, terms, opts)
    end
  end

  # A link must match at least half of the terms, so one loose prefix
  # ("post" in "postmortem") doesn't make a phrase's text hit.
  defp ranked_text(user, terms, opts) do
    # Terms are unaccented and then quoted in Postgres, so a character that
    # unaccent turns into tsquery syntax (U+02D0 into ":") stays in the lexeme.
    needed = div(length(terms) + 1, 2)

    from(l in "links",
      where: l.user_id == type(^user.id, Ecto.UUID),
      where:
        fragment(
          "? @@ (SELECT to_tsquery('simple', string_agg(quote_literal(acervo_unaccent(term)) || ':*', ' | ')) FROM unnest(?::text[]) AS term)",
          l.search_tsv,
          type(^terms, {:array, :string})
        ),
      where:
        fragment(
          "(SELECT count(*) FROM unnest(?::text[]) AS term WHERE ? @@ to_tsquery('simple', quote_literal(acervo_unaccent(term)) || ':*'))",
          type(^terms, {:array, :string}),
          l.search_tsv
        ) >= ^needed,
      order_by: [
        desc:
          fragment(
            "ts_rank_cd(?, (SELECT to_tsquery('simple', string_agg(quote_literal(acervo_unaccent(term)) || ':*', ' | ')) FROM unnest(?::text[]) AS term))",
            l.search_tsv,
            type(^terms, {:array, :string})
          ),
        desc: l.inserted_at,
        desc: l.id
      ],
      limit: @list_size,
      select: {type(l.id, Ecto.UUID), type(l.inserted_at, :utc_datetime)}
    )
    |> scoped(user, opts)
    |> Repo.all()
  end

  @doc false
  # The words of `query` (letters and digits only, three or more, not a
  # common Portuguese or English function word, at most eight) as prefix
  # terms; `text_ranks/3` quotes them in Postgres.
  @spec text_terms(String.t()) :: [String.t()]
  def text_terms(query) when is_binary(query) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(query))
    |> List.flatten()
    |> Enum.filter(&(String.length(&1) >= 3 and not MapSet.member?(@stopwords, &1)))
    |> Enum.uniq()
    |> Enum.take(8)
  end

  @doc """
  The scope's links nearest in meaning to `link`, nearest first: cosine
  distance between embeddings from the configured model, kept only within
  the search's cutoff (`max_distance`, similarity 0.27 or more). The link
  itself and the ids in `:exclude` are left out. Empty when the link has no
  embedding yet. No model call: the link's own vector is the query.

  Options: `:limit` (5 by default, at most 50) and `:exclude`.
  """
  @spec similar_links(Scope.t(), Link.t(), keyword()) :: [Link.t()]
  def similar_links(%Scope{user: user} = scope, %Link{id: id}, opts \\ []) do
    opts = Keyword.validate!(opts, limit: 5, exclude: [])
    model = AI.embedding_model()

    vector =
      Repo.one(
        from l in Link,
          where: l.id == ^id and l.user_id == ^user.id and l.embedding_model == ^model,
          select: l.embedding
      )

    case vector do
      %Pgvector{} ->
        ranks =
          vector_ranks(scope, vector,
            max_distance: config(:max_distance, nil),
            exclude: [id | opts[:exclude]],
            limit: min(opts[:limit], @list_size)
          )

        Library.list_links_by_ids(scope, Enum.map(ranks, &elem(&1, 0)))

      nil ->
        []
    end
  end

  @doc """
  What the link column shows as related to `link`: the links connected by
  hand (`Acervo.Library.list_related/2`, all of them), then the similar ones
  (`similar_links/3`) up to `max` links in all. `more?` says whether more
  similar links exist than fit.
  """
  @spec related_links(Scope.t(), Link.t(), pos_integer()) :: %{
          manual: [Link.t()],
          similar: [Link.t()],
          more?: boolean()
        }
  def related_links(%Scope{} = scope, %Link{} = link, max \\ 5) do
    manual = Library.list_related(scope, link)
    room = max(max - length(manual), 0)
    similar = similar_links(scope, link, limit: room + 1, exclude: Enum.map(manual, & &1.id))

    %{manual: manual, similar: Enum.take(similar, room), more?: length(similar) > room}
  end

  @doc """
  The scope's links that `link` could be related to, matching `query` by
  their words (the full-text list of `search/3`, so the title counts most),
  without the link itself and the ones already related. At most `:limit`
  (8 by default); none for a query without a searchable word.
  """
  @spec relation_candidates(Scope.t(), Link.t(), String.t(), keyword()) :: [Link.t()]
  def relation_candidates(%Scope{} = scope, %Link{id: id} = link, query, opts \\ []) when is_binary(query) do
    opts = Keyword.validate!(opts, limit: 8)
    exclude = MapSet.new([id | Enum.map(Library.list_related(scope, link), & &1.id)])

    ids =
      scope
      |> text_ranks(normalize_query(query))
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&MapSet.member?(exclude, &1))
      |> Enum.take(opts[:limit])

    Library.list_links_by_ids(scope, ids)
  end

  @doc false
  # The top 50 links (or `:limit`) by cosine distance to `vector`, nearest
  # first, among those embedded with the configured model and not in
  # `:exclude`; with `:max_distance`, farther ones are dropped. `relaxed_order` lets HNSW keep scanning past rows the
  # filters reject (so a filtered query still finds 50), at the cost of a
  # slightly unsorted result, which the outer query sorts again.
  @spec vector_ranks(Scope.t(), Pgvector.t(), keyword()) :: ranked()
  def vector_ranks(%Scope{user: user}, %Pgvector{} = vector, opts \\ []) do
    model = AI.embedding_model()

    nearest =
      scoped(
        from(l in Link,
          where: l.user_id == ^user.id and l.embedding_model == ^model and not is_nil(l.embedding),
          where: l.id not in ^Keyword.get(opts, :exclude, []),
          order_by: fragment("? <=> ?", l.embedding, ^vector),
          limit: ^Keyword.get(opts, :limit, @list_size),
          select: %{id: l.id, inserted_at: l.inserted_at, distance: fragment("? <=> ?", l.embedding, ^vector)}
        ),
        user,
        opts
      )

    query =
      from(n in subquery(nearest),
        order_by: [asc: n.distance, desc: n.inserted_at, desc: n.id],
        select: {n.id, n.inserted_at}
      )

    query =
      case opts[:max_distance] do
        nil -> query
        max_distance when is_number(max_distance) -> where(query, [n], n.distance <= ^(max_distance * 1.0))
      end

    {:ok, ranks} =
      Repo.transact(fn ->
        Repo.query!("SET LOCAL hnsw.ef_search = 100")
        Repo.query!("SET LOCAL hnsw.iterative_scan = relaxed_order")
        {:ok, Repo.all(query)}
      end)

    ranks
  end

  # The collection must be the user's: checked here, not trusted.
  defp scoped(query, user, opts) do
    query
    |> by_collection(user, opts[:collection_id])
    |> by_source(opts[:source])
  end

  defp by_collection(query, _user, nil), do: query

  defp by_collection(query, user, collection_id) do
    members =
      from cl in CollectionLink,
        join: c in Collection,
        on: c.id == cl.collection_id,
        where: c.id == ^collection_id and c.user_id == ^user.id,
        select: cl.link_id

    where(query, [l], l.id in subquery(members))
  end

  defp by_source(query, nil), do: query
  defp by_source(query, source) when source in @sources, do: where(query, [l], l.source == ^Atom.to_string(source))

  @doc false
  # Reciprocal Rank Fusion with constant `k`: each id scores the sum of
  # 1 / (k + rank) over the lists it appears in (ranks from 1). Best first;
  # ties go to the newer link, then to the id, so the order is total.
  @spec fuse(ranked(), ranked(), pos_integer()) :: [Ecto.UUID.t()]
  def fuse(text, vector, k \\ @rrf_k) when is_integer(k) and k > 0 do
    [text, vector]
    |> Enum.flat_map(&Enum.with_index(&1, 1))
    |> Enum.reduce(%{}, fn {{id, inserted_at}, rank}, scores ->
      Map.update(scores, id, {1 / (k + rank), inserted_at}, fn {score, at} -> {score + 1 / (k + rank), at} end)
    end)
    |> Enum.sort_by(fn {id, {score, inserted_at}} -> {-score, -DateTime.to_unix(inserted_at, :microsecond), id} end)
    |> Enum.map(fn {id, _score} -> id end)
  end
end
