defmodule Acervo.Repo.Migrations.CreateCollectionSuggestions do
  use Ecto.Migration

  # Collections the AI suggests for a link: an existing collection or a new
  # name with a short reason. Suggestions never apply on their own; the owner
  # accepts or dismisses them. Only one pending suggestion per link and target.
  def change do
    create table(:collection_suggestions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :link_id, references(:links, type: :binary_id, on_delete: :delete_all), null: false
      add :collection_id, references(:collections, type: :binary_id, on_delete: :delete_all)
      add :proposed_name, :string, size: 80
      add :normalized_name, :string, size: 120
      add :reason, :string, size: 140
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create constraint(:collection_suggestions, :target,
             check:
               "collection_id IS NOT NULL OR (proposed_name IS NOT NULL AND normalized_name IS NOT NULL)"
           )

    create unique_index(:collection_suggestions, [:link_id, :collection_id],
             where: "status = 'pending' AND collection_id IS NOT NULL",
             name: :collection_suggestions_pending_collection_index
           )

    create unique_index(:collection_suggestions, [:link_id, :normalized_name],
             where: "status = 'pending' AND collection_id IS NULL",
             name: :collection_suggestions_pending_name_index
           )

    create index(:collection_suggestions, [:user_id, :normalized_name],
             where: "status = 'pending'",
             name: :collection_suggestions_pending_user_name_index
           )

    create index(:collection_suggestions, [:link_id, :status])
    create index(:collection_suggestions, [:collection_id])
  end
end
