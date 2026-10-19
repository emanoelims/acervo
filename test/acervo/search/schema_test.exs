defmodule Acervo.Search.SchemaTest do
  use Acervo.DataCase, async: true

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.FakeEmbedder
  alias Acervo.Library
  alias Acervo.Library.Link

  setup do
    scope = user_scope_fixture()
    %{scope: scope, link: link_fixture(scope)}
  end

  # `search_tsv` is generated and not in the schema, so it is queried from
  # the "links" source without one.
  defp matching_ids(query) do
    Repo.all(
      from l in "links",
        where: fragment("? @@ websearch_to_tsquery('simple', acervo_unaccent(?))", l.search_tsv, ^query),
        select: type(l.id, Ecto.UUID)
    )
  end

  test "saving a link never writes the generated column", %{scope: scope} do
    assert {:ok, %Link{}, :created} = Library.save_link(scope, "https://example.com/another")
  end

  test "search_tsv matches title and note words without accents or case", %{link: link} do
    link |> Link.capture_changeset(%{title: "Inspiração"}) |> Repo.update!()
    link |> Repo.reload!() |> Link.note_changeset(%{note: "café da manhã"}) |> Repo.update!()

    assert matching_ids("inspiracao") == [link.id]
    assert matching_ids("CAFE") == [link.id]
    assert matching_ids("Inspiração café") == [link.id]
    assert matching_ids("chá") == []
  end

  test "search_tsv covers the image description, site, author and excerpt", %{link: link} do
    link
    |> Link.capture_changeset(%{site_name: "Blogue", author: "Ana Souza", text_excerpt: "Um texto sobre pão."})
    |> Repo.update!()

    link |> Repo.reload!() |> Link.enrichment_changeset(%{image_description: "Um farol ao entardecer"}) |> Repo.update!()

    for word <- ["farol", "blogue", "souza", "pao"] do
      assert matching_ids(word) == [link.id], "expected #{word} to match"
    end
  end

  test "search_tsv covers the AI notes", %{link: link} do
    link |> Link.generated_notes_changeset(%{ai_notes: "Resumo sobre colmeias urbanas."}) |> Repo.update!()

    assert matching_ids("colmeias") == [link.id]
  end

  test "the embedding round-trips a 1024-dimension vector and is not loaded by lists", %{scope: scope, link: link} do
    vector = FakeEmbedder.vector("praia")

    link
    |> Link.embedding_changeset(%{
      embedding: Pgvector.new(vector),
      embedding_model: "openrouter:voyageai/voyage-4-lite",
      embedding_digest: :crypto.hash(:sha256, "doc"),
      embedding_status: :ready,
      embedded_at: DateTime.utc_now(:second)
    })
    |> Repo.update!()

    stored = Repo.one!(from l in Link, where: l.id == ^link.id, select: l.embedding)
    assert stored |> Pgvector.to_list() |> length() == 1024
    assert_in_delta stored |> Pgvector.to_list() |> hd(), hd(vector), 1.0e-6

    assert [listed] = Library.list_links(scope)
    assert listed.embedding == nil
    assert listed.embedding_digest == nil
    assert listed.embedding_status == :ready
    assert listed.embedding_model == "openrouter:voyageai/voyage-4-lite"
  end

  test "the column rejects a vector of another length", %{link: link} do
    assert_raise Postgrex.Error, ~r/expected 1024 dimensions, not 3/, fn ->
      link |> Link.embedding_changeset(%{embedding: Pgvector.new([1.0, 2.0, 3.0])}) |> Repo.update!()
    end
  end
end
