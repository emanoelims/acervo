defmodule Acervo.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  import Ecto.Query

  alias Acervo.Library.ExtractContent
  alias Acervo.Library.Link

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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    {:ok, _started} = Application.ensure_all_started(:ssl)
    :ok = Application.ensure_loaded(@app)
  end
end
