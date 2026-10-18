defmodule Acervo.Repo.Migrations.AddSearchToLinks do
  use Ecto.Migration

  # Search over links: a 1024-dimension embedding of each link's text (with
  # the model and a digest of what was embedded, so unchanged text is never
  # re-embedded) and a stored full-text vector.
  #
  # Postgres 18 makes generated columns VIRTUAL by default, and virtual
  # columns cannot be indexed, so `search_tsv` says STORED. `acervo_unaccent`
  # is STRICT, hence the coalesces inside it. Adding the stored column
  # rewrites `links` once under this migration's lock.
  #
  # The indexes are built without CONCURRENTLY: the table is small, and every
  # embedding is NULL here, so the HNSW build is instant. Past about 100k
  # rows, `@disable_ddl_transaction` with CONCURRENTLY would be the route.
  def up do
    alter table(:links) do
      add :embedding, :vector, size: 1024
      add :embedding_model, :string, size: 200
      add :embedding_digest, :binary
      # nil means never enqueued; then pending, ready or failed.
      add :embedding_status, :string
      add :embedded_at, :utc_datetime
    end

    execute """
    ALTER TABLE links ADD COLUMN search_tsv tsvector GENERATED ALWAYS AS (
      setweight(to_tsvector('simple'::regconfig, acervo_unaccent(coalesce(title, ''))), 'A') ||
      setweight(to_tsvector('simple'::regconfig, acervo_unaccent(
        coalesce(description, '') || ' ' || coalesce(image_description, '') || ' ' || coalesce(note, ''))), 'B') ||
      setweight(to_tsvector('simple'::regconfig, acervo_unaccent(
        coalesce(site_name, '') || ' ' || coalesce(author, '') || ' ' || coalesce(text_excerpt, ''))), 'C')
    ) STORED
    """

    execute "CREATE INDEX links_search_tsv_index ON links USING gin (search_tsv)"
    execute "CREATE INDEX links_embedding_index ON links USING hnsw (embedding vector_cosine_ops)"

    # The inbox list and count.
    execute """
    CREATE INDEX links_inbox_index ON links (user_id, inserted_at DESC)
      WHERE triaged_at IS NULL
    """

    # The stuck-work reaper's three passes.
    execute """
    CREATE INDEX links_stuck_index ON links (updated_at)
      WHERE status IN ('pending', 'processing')
        OR enrichment_status = 'pending'
        OR embedding_status = 'pending'
    """
  end

  def down do
    execute "DROP INDEX links_stuck_index"
    execute "DROP INDEX links_inbox_index"
    execute "DROP INDEX links_embedding_index"
    execute "DROP INDEX links_search_tsv_index"
    execute "ALTER TABLE links DROP COLUMN search_tsv"

    alter table(:links) do
      remove :embedded_at
      remove :embedding_status
      remove :embedding_digest
      remove :embedding_model
      remove :embedding
    end
  end
end
