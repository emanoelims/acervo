defmodule Acervo.Repo.Migrations.CreateCollections do
  use Ecto.Migration

  def change do
    create table(:collections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, size: 80, null: false
      add :slug, :string, size: 80, null: false
      add :description, :string, size: 280
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:collections, [:user_id, :slug])

    create table(:collection_links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :collection_id, references(:collections, type: :binary_id, on_delete: :delete_all),
        null: false

      add :link_id, references(:links, type: :binary_id, on_delete: :delete_all), null: false
      add :source, :string, null: false, default: "manual"

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:collection_links, [:collection_id, :link_id])
    create index(:collection_links, [:link_id])
  end
end
