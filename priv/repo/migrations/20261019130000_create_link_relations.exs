defmodule Acervo.Repo.Migrations.CreateLinkRelations do
  use Ecto.Migration

  # Links the owner connected by hand. A relation is symmetric, so each pair
  # is stored once, the smaller id first; the unique index then rejects the
  # same pair in either order.
  def change do
    create table(:link_relations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :link_a_id, references(:links, type: :binary_id, on_delete: :delete_all), null: false
      add :link_b_id, references(:links, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create constraint(:link_relations, :link_relations_ordered, check: "link_a_id < link_b_id")
    create unique_index(:link_relations, [:link_a_id, :link_b_id])
    create index(:link_relations, [:link_b_id])
    create index(:link_relations, [:user_id])
  end
end
