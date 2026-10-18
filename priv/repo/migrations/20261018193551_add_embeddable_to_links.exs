defmodule Acervo.Repo.Migrations.AddEmbeddableToLinks do
  use Ecto.Migration

  # Whether the page may be shown in a frame, read from its response headers
  # during capture. Null until known: older links are checked on first view.
  def change do
    alter table(:links) do
      add :embeddable, :boolean
    end
  end
end
