defmodule Acervo.Repo.Migrations.EnableExtensions do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS citext"
    execute "CREATE EXTENSION IF NOT EXISTS unaccent"
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    # unaccent/1 is STABLE; the two-argument form with an explicit dictionary is
    # safe to wrap as IMMUTABLE so generated tsvector columns can use it.
    execute """
    CREATE FUNCTION acervo_unaccent(text) RETURNS text
      LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
      RETURN public.unaccent('public.unaccent'::regdictionary, $1)
    """
  end

  def down do
    execute "DROP FUNCTION IF EXISTS acervo_unaccent(text)"
    execute "DROP EXTENSION IF EXISTS vector"
    execute "DROP EXTENSION IF EXISTS unaccent"
    execute "DROP EXTENSION IF EXISTS citext"
  end
end
