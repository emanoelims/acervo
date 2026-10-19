defmodule Acervo.Repo.Migrations.CreateBookmarkImports do
  use Ecto.Migration

  # One row per bookmarks import. The uploaded file is never stored: only the
  # entries left to save, as a jsonb array (`entries[cursor + 1 : cursor + 50]`
  # is one batch), and the names of the collections they go to. Both are
  # cleared once the import ends.
  def change do
    create table(:bookmark_imports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :found, :integer, null: false, default: 0
      add :truncated, :integer, null: false, default: 0
      add :total, :integer, null: false, default: 0
      add :processed, :integer, null: false, default: 0
      add :created, :integer, null: false, default: 0
      add :existing, :integer, null: false, default: 0
      add :failed, :integer, null: false, default: 0
      add :choices, :map, null: false, default: %{}
      add :collections, {:array, :string}, null: false, default: []
      add :entries, {:array, :map}, null: false, default: []
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:bookmark_imports, [:user_id, :inserted_at])
    # At most one running import per user.
    create unique_index(:bookmark_imports, [:user_id],
             where: "status = 'running'",
             name: :bookmark_imports_one_running_index
           )
  end
end
