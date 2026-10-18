defmodule Acervo.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    {:ok, _started} = Application.ensure_all_started(:ssl)
    :ok = Application.ensure_loaded(@app)
  end
end
