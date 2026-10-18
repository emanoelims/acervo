defmodule Acervo.Repo.Migrations.AddEnrichmentToLinks do
  use Ecto.Migration

  # The AI enrichment of a link: its first image described in words (editable
  # by the owner), the page's language and the enrichment's state. A null
  # `enrichment_status` means the link was never enqueued for enrichment.
  def change do
    alter table(:links) do
      add :image_description, :text
      add :image_description_edited_at, :utc_datetime
      add :language, :string, size: 16
      add :enrichment_status, :string
      add :enriched_at, :utc_datetime
    end
  end
end
