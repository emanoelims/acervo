defmodule Acervo.Repo.Migrations.AddResolvedUrlToLinks do
  use Ecto.Migration

  def change do
    alter table(:links) do
      add :resolved_url, :string, size: 2048
    end

    create index(:links, [:user_id, :resolved_url])
  end
end
