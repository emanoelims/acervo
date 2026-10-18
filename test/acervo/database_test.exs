defmodule Acervo.DatabaseTest do
  use Acervo.DataCase, async: true

  alias Acervo.Repo

  test "required extensions are installed" do
    %{rows: rows} = Repo.query!("SELECT extname FROM pg_extension ORDER BY extname")
    names = List.flatten(rows)

    for ext <- ~w(citext unaccent vector), do: assert(ext in names)
  end

  test "acervo_unaccent removes accents and is immutable" do
    assert %{rows: [["Cafe acucar"]]} = Repo.query!("SELECT acervo_unaccent('Café açúcar')")

    assert %{rows: [["i"]]} =
             Repo.query!("SELECT provolatile::text FROM pg_proc WHERE proname = 'acervo_unaccent'")
  end

  test "pgvector values round-trip through Postgrex" do
    %{rows: [[vector]]} = Repo.query!("SELECT '[1,2,3]'::vector")
    assert Pgvector.to_list(vector) == [1.0, 2.0, 3.0]
  end

  test "oban_jobs table exists" do
    assert %{rows: [[true]]} = Repo.query!("SELECT to_regclass('public.oban_jobs') IS NOT NULL")
  end
end
