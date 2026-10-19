defmodule Acervo.Repo.Migrations.AddAiNotesToLinks do
  use Ecto.Migration

  # AI notes: a summary and key points the model writes on request, kept
  # apart from the owner's note. They join the full-text vector at the
  # lowest weight, after the title (A), the description, image description
  # and note (B) and the site, author and excerpt (C).
  #
  # SET EXPRESSION (Postgres 17+) rewrites `links` and its indexes once under
  # this migration's lock, keeping `links_search_tsv_index`.
  @with_notes """
  setweight(to_tsvector('simple'::regconfig, acervo_unaccent(coalesce(title, ''))), 'A') ||
  setweight(to_tsvector('simple'::regconfig, acervo_unaccent(
    coalesce(description, '') || ' ' || coalesce(image_description, '') || ' ' || coalesce(note, ''))), 'B') ||
  setweight(to_tsvector('simple'::regconfig, acervo_unaccent(
    coalesce(site_name, '') || ' ' || coalesce(author, '') || ' ' || coalesce(text_excerpt, ''))), 'C') ||
  setweight(to_tsvector('simple'::regconfig, acervo_unaccent(coalesce(ai_notes, ''))), 'D')
  """

  @without_notes """
  setweight(to_tsvector('simple'::regconfig, acervo_unaccent(coalesce(title, ''))), 'A') ||
  setweight(to_tsvector('simple'::regconfig, acervo_unaccent(
    coalesce(description, '') || ' ' || coalesce(image_description, '') || ' ' || coalesce(note, ''))), 'B') ||
  setweight(to_tsvector('simple'::regconfig, acervo_unaccent(
    coalesce(site_name, '') || ' ' || coalesce(author, '') || ' ' || coalesce(text_excerpt, ''))), 'C')
  """

  def up do
    alter table(:links) do
      add :ai_notes, :text
      add :ai_notes_at, :utc_datetime
    end

    execute "ALTER TABLE links ALTER COLUMN search_tsv SET EXPRESSION AS (#{@with_notes})"
  end

  def down do
    execute "ALTER TABLE links ALTER COLUMN search_tsv SET EXPRESSION AS (#{@without_notes})"

    alter table(:links) do
      remove :ai_notes_at
      remove :ai_notes
    end
  end
end
