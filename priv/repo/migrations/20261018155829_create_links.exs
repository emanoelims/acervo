defmodule Acervo.Repo.Migrations.CreateLinks do
  use Ecto.Migration

  def change do
    create table(:links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :url, :string, size: 2048, null: false
      add :canonical_url, :string, size: 2048, null: false
      add :source, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :capture_error, :text
      add :title, :text
      add :description, :text
      add :author, :text
      add :site_name, :text
      add :published_at, :utc_datetime
      add :text_excerpt, :text
      add :note, :text
      add :triaged_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:links, [:user_id, :canonical_url])
    create index(:links, [:user_id, :inserted_at])
  end
end
