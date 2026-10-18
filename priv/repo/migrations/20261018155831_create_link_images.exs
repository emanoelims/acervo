defmodule Acervo.Repo.Migrations.CreateLinkImages do
  use Ecto.Migration

  def change do
    create table(:link_images, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :link_id, references(:links, type: :binary_id, on_delete: :delete_all), null: false
      add :position, :integer, null: false, default: 0
      add :kind, :string, null: false
      add :content_type, :string, null: false
      add :bytes, :binary, null: false
      add :width, :integer
      add :height, :integer
      add :sha256, :string

      timestamps(type: :utc_datetime)
    end

    create index(:link_images, [:link_id, :position])
  end
end
