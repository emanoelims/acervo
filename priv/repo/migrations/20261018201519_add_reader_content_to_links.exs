defmodule Acervo.Repo.Migrations.AddReaderContentToLinks do
  use Ecto.Migration

  # The page's article as sanitized HTML for the reader view, where it came
  # from (the page's Markdown or its HTML), and when it was last extracted,
  # found or not. Null on links captured before: a backfill fills them.
  # Inline images are `link_images` of kind "content", no schema change.
  def change do
    alter table(:links) do
      add :content_html, :text
      add :content_source, :string
      add :content_extracted_at, :utc_datetime
    end
  end
end
