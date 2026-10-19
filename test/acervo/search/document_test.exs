defmodule Acervo.Search.DocumentTest do
  use Acervo.DataCase, async: true

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.Collections
  alias Acervo.Collections.CollectionLink
  alias Acervo.Library.Link
  alias Acervo.Search.Document

  setup do
    %{scope: user_scope_fixture()}
  end

  defp ready_link(scope, attrs) do
    link = link_fixture(scope, "https://www.example.com/posts/#{System.unique_integer([:positive])}")
    Repo.update_all(from(l in Link, where: l.id == ^link.id), set: Keyword.merge([status: :ready], attrs))
    Repo.get!(Link, link.id)
  end

  defp build!(scope, link) do
    {:ok, text} = Document.build(scope, link)
    text
  end

  test "one labelled line per present field, highest signal first", %{scope: scope} do
    link =
      ready_link(scope,
        title: "Bees",
        site_name: "Example Journal",
        author: "Jane Roe",
        description: "All about bees.",
        image_description: "A bee on a flower.",
        note: "for the garden\nask Ana",
        ai_notes: "Bees matter.\n\n- They pollinate.",
        text_excerpt: "Bees pollinate crops."
      )

    for name <- ["Zoology", "Apiculture"] do
      :ok = Collections.add_link(scope, collection_fixture(scope, %{name: name}), link)
    end

    assert build!(scope, link) ==
             """
             Title: Bees
             Site: Example Journal
             Author: Jane Roe
             Collections: Apiculture, Zoology
             Description: All about bees.
             Image: A bee on a flower.
             Note: for the garden
             ask Ana
             AI notes: Bees matter.
             - They pollinate.
             Text: Bees pollinate crops.\
             """
  end

  test "skips blank fields and falls back to the URL's host for the site", %{scope: scope} do
    link = ready_link(scope, title: "Bees", description: "   ", author: nil)

    assert build!(scope, link) == "Title: Bees\nSite: www.example.com"
  end

  test "lists only the scope's collections", %{scope: scope} do
    link = ready_link(scope, title: "Bees")
    other = user_scope_fixture()
    theirs = collection_fixture(other, %{name: "Secret"})

    # Impossible through the context, but the query must not trust the join.
    Repo.insert!(%CollectionLink{collection_id: theirs.id, link_id: link.id})

    refute build!(scope, link) =~ "Secret"
  end

  test "prefers the reader content over the excerpt", %{scope: scope} do
    link = ready_link(scope, title: "Bees", text_excerpt: "the excerpt")
    link |> Link.content_changeset(%{content_html: "<h1>Hive</h1><p>The  article</p>"}) |> Repo.update!()

    assert build!(scope, link) =~ "Text: Hive\nThe article"
    refute build!(scope, link) =~ "excerpt"
  end

  test "clips the text at 6,000 characters and the whole at 8,000, on a word boundary", %{scope: scope} do
    words = String.duplicate("honey ", 1_400)
    link = ready_link(scope, title: "Bees", text_excerpt: words)

    "Text: " <> text = scope |> build!(link) |> String.split("\n") |> List.last()
    assert String.length(text) <= 6_000
    assert String.ends_with?(text, "honey")

    long =
      ready_link(scope,
        title: "Bees",
        description: String.duplicate("pollen ", 285),
        note: String.duplicate("nectar ", 570),
        text_excerpt: words
      )

    document = build!(scope, long)
    assert String.length(document) <= 8_000
    assert String.length(document) > 7_900
    assert String.ends_with?(document, "honey")
  end

  test "strips NUL and control characters", %{scope: scope} do
    link = ready_link(scope, title: "Bees")
    # Postgres text rejects NUL, so the struct carries it.
    link = %{link | note: "a\0b\x07c\r\nd", title: "Be\x1Bes"}

    assert build!(scope, link) =~ "Title: Bees\n"
    assert String.ends_with?(build!(scope, link), "Note: abc\nd")
    refute build!(scope, link) =~ <<0>>
  end

  test "skips a link with nothing to embed", %{scope: scope} do
    link = ready_link(scope, site_name: "Example Journal", author: "Jane Roe")
    :ok = Collections.add_link(scope, collection_fixture(scope), link)

    assert Document.build(scope, link) == :skip
  end

  test "the digest changes with the text and with the model", %{scope: scope} do
    link = ready_link(scope, title: "Bees")
    text = build!(scope, link)
    noted = build!(scope, %{link | note: "a note"})

    assert byte_size(Document.digest("model-a", text)) == 32
    assert Document.digest("model-a", text) == Document.digest("model-a", text)
    refute Document.digest("model-a", text) == Document.digest("model-a", noted)
    refute Document.digest("model-a", text) == Document.digest("model-b", text)
  end
end
