defmodule Acervo.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  import Ecto.Query

  alias Acervo.AI
  alias Acervo.AI.EnrichLink
  alias Acervo.Library.ExtractContent
  alias Acervo.Library.Link
  alias Acervo.Search.EmbedLink

  @app :acervo

  @doc "Applies all pending migrations, raising if the repository cannot start or a migration fails."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    Enum.each(repos(), fn repo ->
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end)
  end

  @doc "Rolls a repository back to the given migration version, raising on failure."
  @spec rollback(module(), non_neg_integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc """
  Enqueues `Acervo.Library.ExtractContent` for every ready generic link
  whose reader view was never extracted, and returns how many were enqueued.
  The running app's `content` queue works through them, one at a time.

  Starts only the repository and an Oban instance that runs no queues, so it
  is safe next to the running app:

      bin/acervo eval 'Acervo.Release.backfill_reader_content()'
  """
  @spec backfill_reader_content() :: non_neg_integer()
  def backfill_reader_content do
    load_app()
    {:ok, _started} = Application.ensure_all_started(:oban)
    [repo] = repos()

    {:ok, count, _apps} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        name = Acervo.Release.Oban
        config = Keyword.merge(Application.fetch_env!(@app, Oban), name: name, queues: false, plugins: false, peer: false)
        {:ok, oban} = Oban.start_link(config)

        try do
          repo
          |> missing_reader_content()
          |> Enum.count(&match?({:ok, _job}, Oban.insert(name, ExtractContent.new(%{"link_id" => &1}))))
        after
          Supervisor.stop(oban)
        end
      end)

    IO.puts("Enqueued reader content for #{count} links.")
    count
  end

  @doc false
  @spec missing_reader_content(module()) :: [Ecto.UUID.t()]
  def missing_reader_content(repo) do
    repo.all(
      from l in Link,
        where: l.source == :generic and l.status == :ready,
        where: is_nil(l.capture_error) and is_nil(l.content_extracted_at),
        order_by: [desc: l.inserted_at],
        select: l.id
    )
  end

  @doc """
  Enqueues `Acervo.AI.EnrichLink` for every ready link that was never
  enriched or whose enrichment failed, newest first, marks them `:pending`
  and returns how many were enqueued. The running app's `ai` queue works
  through them. Every link gets its image description and language; only
  links still in the inbox get suggestions.

  Each link costs one model call. Run `backfill_reader_content/0` first, so
  the model reads the article. Starts only the repository and an Oban
  instance that runs no queues:

      bin/acervo eval 'Acervo.Release.backfill_enrichment()'
  """
  @spec backfill_enrichment() :: non_neg_integer()
  def backfill_enrichment do
    load_app()
    {:ok, _started} = Application.ensure_all_started(:oban)
    [repo] = repos()

    {:ok, count, _apps} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        name = Acervo.Release.Oban
        config = Keyword.merge(Application.fetch_env!(@app, Oban), name: name, queues: false, plugins: false, peer: false)
        {:ok, oban} = Oban.start_link(config)

        try do
          repo
          |> missing_enrichment()
          |> Enum.count(fn id ->
            case Oban.insert(name, EnrichLink.new(%{"link_id" => id})) do
              {:ok, _job} ->
                repo.update_all(from(l in Link, where: l.id == ^id), set: [enrichment_status: :pending])
                true

              _ ->
                false
            end
          end)
        after
          Supervisor.stop(oban)
        end
      end)

    IO.puts("Enqueued enrichment for #{count} links.")
    count
  end

  @doc false
  @spec missing_enrichment(module()) :: [Ecto.UUID.t()]
  def missing_enrichment(repo) do
    repo.all(
      from l in Link,
        where: l.status == :ready and (is_nil(l.enrichment_status) or l.enrichment_status == :failed),
        order_by: [desc: l.inserted_at],
        select: l.id
    )
  end

  @doc """
  Enqueues `Acervo.Search.EmbedLink` for every ready link whose embedding
  was never made or was made with another model than the configured one,
  newest first (in transactions of 200 links, so the newest are scheduled
  first), marks them `:pending` and returns how many were enqueued.
  The running app's `embed` queue works through them. Run it after deploying
  search and after changing `ACERVO_EMBEDDING_MODEL`; meanwhile text search
  keeps working and the vector side sees only links already on the new model.

  `all: true` enqueues every ready link instead, for a change in the
  embedded document's format. Each job compares the document's digest with
  the stored one, so a link whose text and model are unchanged costs no call.
  Links already `:pending` are left to their job. Starts only the repository
  and an Oban instance that runs no queues:

      bin/acervo eval 'Acervo.Release.reindex()'
  """
  @spec reindex(keyword()) :: non_neg_integer()
  def reindex(opts \\ []) do
    opts = Keyword.validate!(opts, all: false)
    load_app()
    {:ok, _started} = Application.ensure_all_started(:oban)
    [repo] = repos()

    {:ok, count, _apps} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        name = Acervo.Release.Oban
        config = Keyword.merge(Application.fetch_env!(@app, Oban), name: name, queues: false, plugins: false, peer: false)
        {:ok, oban} = Oban.start_link(config)

        try do
          {:ok, count} = repo |> stale_embeddings(opts) |> EmbedLink.enqueue_many(oban: name)
          count
        after
          Supervisor.stop(oban)
        end
      end)

    IO.puts("Enqueued embedding for #{count} links.")
    count
  end

  @doc false
  # Ready links not `:pending` whose `embedding_model` is nil or not the
  # configured model; with `all: true`, every ready link not `:pending`.
  @spec stale_embeddings(module(), keyword()) :: [Ecto.UUID.t()]
  def stale_embeddings(repo, opts \\ []) do
    model = AI.embedding_model()

    query =
      from l in Link,
        where: l.status == :ready,
        where: is_nil(l.embedding_status) or l.embedding_status != :pending,
        order_by: [desc: l.inserted_at],
        select: l.id

    query =
      if Keyword.get(opts, :all, false),
        do: query,
        else: where(query, [l], is_nil(l.embedding_model) or l.embedding_model != ^model)

    repo.all(query)
  end

  @doc """
  Prints the model calls of the last `days` days (default 30) per day: calls,
  tokens in and out, and USD, with a total. Costs are estimates from
  `Acervo.AI.Rates`.

      bin/acervo eval 'Acervo.Release.ai_costs()'
  """
  @spec ai_costs(pos_integer()) :: :ok
  def ai_costs(days \\ 30) do
    load_app()
    [repo] = repos()
    {:ok, rows, _apps} = Ecto.Migrator.with_repo(repo, fn _repo -> AI.cost_summary(days) end)

    lines =
      Enum.map(rows, fn row ->
        cost_line(Date.to_iso8601(row.day), row.calls, row.input_tokens, row.output_tokens, row.cost_usd)
      end)

    total =
      cost_line(
        "total",
        rows |> Enum.map(& &1.calls) |> Enum.sum(),
        rows |> Enum.map(& &1.input_tokens) |> Enum.sum(),
        rows |> Enum.map(& &1.output_tokens) |> Enum.sum(),
        rows |> Enum.map(& &1.cost_usd) |> Enum.reject(&is_nil/1) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      )

    IO.puts(cost_line("day", "calls", "tokens in", "tokens out", "USD"))
    Enum.each(lines, &IO.puts/1)
    IO.puts(total)
  end

  defp cost_line(day, calls, input, output, cost) do
    [day, calls, input, output, format_cost(cost)]
    |> Enum.zip([10, 7, 12, 12, 10])
    |> Enum.map_join("  ", fn {value, width} -> value |> to_string() |> String.pad_leading(width) end)
  end

  defp format_cost(nil), do: "-"
  defp format_cost(%Decimal{} = cost), do: cost |> Decimal.round(4) |> Decimal.to_string(:normal)
  defp format_cost(cost), do: cost

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    {:ok, _started} = Application.ensure_all_started(:ssl)
    :ok = Application.ensure_loaded(@app)
  end
end
