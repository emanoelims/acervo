defmodule Acervo.SearchTest do
  use Acervo.DataCase, async: true

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.AI
  alias Acervo.AI.Call
  alias Acervo.Collections.CollectionLink
  alias Acervo.FakeEmbedder
  alias Acervo.Library.Link
  alias Acervo.Search
  alias Acervo.Search.QueryCache

  setup do
    %{scope: user_scope_fixture()}
  end

  # A ready link with the given fields; `vector:` stores an embedding from the
  # configured model (or `model:`), `age:` makes it that many minutes older.
  defp link(scope, attrs) do
    {vector, attrs} = Keyword.pop(attrs, :vector)
    {model, attrs} = Keyword.pop(attrs, :model, AI.embedding_model())
    {age, attrs} = Keyword.pop(attrs, :age, 0)

    link = link_fixture(scope)
    inserted_at = :second |> DateTime.utc_now() |> DateTime.shift(minute: -age)

    embedding =
      if vector, do: [embedding: Pgvector.new(vector), embedding_model: model, embedding_status: :ready], else: []

    Repo.update_all(
      from(l in Link, where: l.id == ^link.id),
      set: Keyword.merge([status: :ready, inserted_at: inserted_at] ++ embedding, attrs)
    )

    Repo.get!(Link, link.id)
  end

  defp stub_query_vector(vector), do: FakeEmbedder.stub(fn _model, _text, _opts -> {:ok, vector} end)

  defp ids(%{links: links}), do: Enum.map(links, & &1.id)

  defp at(minutes_ago), do: :second |> DateTime.utc_now() |> DateTime.shift(minute: -minutes_ago)

  describe "fuse/3" do
    test "an item in both lists beats items in one" do
      assert ["b", "a", "c"] = Search.fuse([{"a", at(0)}, {"b", at(1)}], [{"b", at(1)}, {"c", at(2)}], 60)
    end

    test "rank 1 beats rank 2 in the same list" do
      assert ["old", "new"] = Search.fuse([{"old", at(10)}, {"new", at(0)}], [], 60)
    end

    test "equal scores go to the newer link" do
      # Rank 1 in each list: 1/61 each.
      assert ["new", "old"] = Search.fuse([{"old", at(10)}], [{"new", at(0)}], 60)
    end

    test "an empty vector list keeps the text order" do
      text = [{"a", at(5)}, {"b", at(0)}, {"c", at(3)}]
      assert ["a", "b", "c"] = Search.fuse(text, [], 60)
    end

    test "uses k in the score" do
      # k = 1: b = 1/3 + 1/2, c = 1/2, a = 1/3.
      assert ["b", "c", "a"] = Search.fuse([{"c", at(0)}, {"b", at(0)}], [{"b", at(0)}, {"a", at(0)}], 1)
    end
  end

  describe "search/3" do
    test "fuses text and vector ranks with RRF", %{scope: scope} do
      # A: the word, far vector (dropped by the cutoff). B: no word, the
      # query's own vector. C: the word and a near vector (cosine 0.707).
      a = link(scope, title: "Honeybee dance", vector: FakeEmbedder.axis(1), age: 10)
      b = link(scope, title: "Waggle", vector: FakeEmbedder.axis(0), age: 5)
      c = link(scope, title: "Honeybee hive", vector: FakeEmbedder.blend([{0, 1.0}, {1, 1.0}]), age: 0)
      stub_query_vector(FakeEmbedder.axis(0))

      # Text: C (newer), A. Vector: B, C (A is past 0.73).
      text = [c.id, a.id]
      vector = [b.id, c.id]

      expected =
        [text, vector]
        |> Enum.flat_map(&Enum.with_index(&1, 1))
        |> Enum.reduce(%{}, fn {id, rank}, acc -> Map.update(acc, id, 1 / (60 + rank), &(&1 + 1 / (60 + rank))) end)
        |> Enum.sort_by(fn {_id, score} -> -score end)
        |> Enum.map(&elem(&1, 0))

      assert expected == [c.id, b.id, a.id]
      assert %{partial: false} = result = Search.search(scope, "honeybee")
      assert ids(result) == expected
    end

    test "ranks with k = 60: rank 4 in both lists beats rank 1 in one", %{scope: scope} do
      # Equal titles, so text ranks follow age: x, p, q, y. Vector ranks
      # follow distance: v1, v2, v3, y (x, p, q are orthogonal, past the
      # cutoff). y scores 2/64 against x's 1/61; with k <= 2, x would win.
      far = FakeEmbedder.axis(2)
      x = link(scope, title: "Honeybee", vector: far, age: 0)
      p = link(scope, title: "Honeybee", vector: far, age: 1)
      q = link(scope, title: "Honeybee", vector: far, age: 2)
      y = link(scope, title: "Honeybee", vector: FakeEmbedder.blend([{0, 1.0}, {1, 0.6}]), age: 3)
      v1 = link(scope, title: "Waggle", vector: FakeEmbedder.axis(0), age: 4)
      v2 = link(scope, title: "Waggle", vector: FakeEmbedder.blend([{0, 1.0}, {1, 0.2}]), age: 5)
      v3 = link(scope, title: "Waggle", vector: FakeEmbedder.blend([{0, 1.0}, {1, 0.4}]), age: 6)
      stub_query_vector(FakeEmbedder.axis(0))

      text = [x, p, q, y]
      vector = [v1, v2, v3, y]

      expected =
        [text, vector]
        |> Enum.flat_map(&Enum.with_index(&1, 1))
        |> Enum.reduce(%{}, fn {link, rank}, acc ->
          Map.update(acc, link, 1 / (60 + rank), &(&1 + 1 / (60 + rank)))
        end)
        |> Enum.sort_by(fn {link, score} -> {-score, -DateTime.to_unix(link.inserted_at)} end)
        |> Enum.map(fn {link, _score} -> link.id end)

      assert [first | _] = expected
      assert first == y.id
      assert Enum.map(Search.text_ranks(scope, "honeybee"), &elem(&1, 0)) == Enum.map(text, & &1.id)

      assert Enum.map(Search.vector_ranks(scope, Pgvector.new(FakeEmbedder.axis(0)), max_distance: 0.73), &elem(&1, 0)) ==
               Enum.map(vector, & &1.id)

      assert %{partial: false} = result = Search.search(scope, "honeybee")
      assert ids(result) == expected
    end

    test "keeps text hits past the vector cutoff and drops far vector-only hits", %{scope: scope} do
      # word: orthogonal (distance 1). near: cosine 1/sqrt(5) = 0.447,
      # distance 0.553. far: cosine 1/sqrt(17) = 0.243, distance 0.757.
      word = link(scope, title: "Pollen", vector: FakeEmbedder.axis(5))
      near = link(scope, title: "Near", vector: FakeEmbedder.blend([{0, 1.0}, {7, 2.0}]))
      far = link(scope, title: "Far", vector: FakeEmbedder.blend([{0, 1.0}, {7, 4.0}]))
      stub_query_vector(FakeEmbedder.axis(0))

      assert %{partial: false} = result = Search.search(scope, "pollen")
      assert word.id in ids(result)
      assert near.id in ids(result)
      refute far.id in ids(result)
    end

    test "a query that matches nothing finds nothing", %{scope: scope} do
      link(scope, title: "Bees", vector: FakeEmbedder.axis(1))
      stub_query_vector(FakeEmbedder.axis(0))

      assert %{links: [], partial: false} = Search.search(scope, "xyzzy plover")
    end

    test "finds a link by its image description, by text and by vector", %{scope: scope} do
      link = link(scope, image_description: "Um cachorro correndo na praia", vector: FakeEmbedder.axis(3))
      stub_query_vector(FakeEmbedder.axis(3))

      assert [{id, _}] = Search.text_ranks(scope, "cachorro praia")
      assert id == link.id
      assert [{^id, _}] = Search.vector_ranks(scope, Pgvector.new(FakeEmbedder.axis(3)), max_distance: 0.73)
      assert %{links: [%{id: ^id}], partial: false} = Search.search(scope, "cachorro praia")
    end

    test "a natural phrase finds its link by any word, prefixes included", %{scope: scope} do
      interop = link(scope, title: "JavaScript interoperability in Phoenix LiveView")
      both = link(scope, title: "LiveView JavaScript hooks")
      _other = link(scope, title: "Sourdough at home")

      assert Enum.map(Search.text_ranks(scope, "aquele post sobre interop de javascript"), &elem(&1, 0)) ==
               [interop.id, both.id]
    end

    test "a link must match at least half of the meaningful words", %{scope: scope} do
      _loose = link(scope, title: "Postmortem of a GitHub outage")
      js = link(scope, title: "JavaScript interoperability in Phoenix LiveView")

      assert Enum.map(Search.text_ranks(scope, "aquele post sobre interop de javascript"), &elem(&1, 0)) == [js.id]
      assert scope |> Search.text_ranks("javascript github elixir phoenix") |> length() == 1
    end

    test "builds a prefix OR tsquery from words of three letters or more" do
      assert Search.text_terms("Aquele post sobre interop de JS") == ["interop"]
      assert Search.text_terms("queda do github") == ["queda", "github"]

      assert Search.text_terms("a & | ! :* <-> é") == []
      assert Search.text_terms("foo:* & !bar") == ["foo", "bar"]
      assert 1..20 |> Enum.map_join(" ", &"word#{&1}") |> Search.text_terms() |> length() == 8
    end

    test "matches accents and case either way", %{scope: scope} do
      inspiration = link(scope, title: "Inspiração")
      coffee = link(scope, note: "café")
      FakeEmbedder.stub(fn _model, _text, _opts -> {:error, :unavailable} end)

      assert ids(Search.search(scope, "inspiracao")) == [inspiration.id]
      assert ids(Search.search(scope, "CAFÉ")) == [coffee.id]
    end

    test "a query under 2 characters returns nothing and embeds nothing", %{scope: scope} do
      link(scope, title: "a")

      assert %{links: [], partial: false} = Search.search(scope, "a")
      assert %{links: [], partial: false} = Search.search(scope, "  \u0000 ")
      assert FakeEmbedder.calls() == 0
    end

    test "records the query embedding as embed_query", %{scope: scope} do
      Search.search(scope, "bees")

      assert [%Call{operation: "embed_query", link_id: nil, status: :ok, output_tokens: 0}] =
               Repo.all(from c in Call, where: c.user_id == ^scope.user.id)
    end

    test "respects the limit", %{scope: scope} do
      for _i <- 1..3, do: link(scope, title: "Bees")

      assert length(Search.search(scope, "bees", limit: 2).links) == 2
    end
  end

  describe "fallback" do
    test "an embedding error returns text results flagged partial", %{scope: scope} do
      link = link(scope, title: "Bees")
      FakeEmbedder.stub(fn _model, _text, _opts -> {:error, {:http, 500}} end)

      assert %{links: [%{id: id}], partial: true} = Search.search(scope, "bees")
      assert id == link.id
    end

    test "a crashed embedding returns text results flagged partial", %{scope: scope} do
      link = link(scope, title: "Bees")
      FakeEmbedder.stub(fn _model, _text, _opts -> raise "boom" end)

      {result, _log} = ExUnit.CaptureLog.with_log(fn -> Search.search(scope, "bees") end)
      assert %{links: [%{id: id}], partial: true} = result
      assert id == link.id
    end

    test "a slow embedding returns text results in time, then still records and caches", %{scope: scope} do
      link = link(scope, title: "Bees", vector: FakeEmbedder.axis(0))
      test = self()

      FakeEmbedder.stub(fn _model, _text, opts ->
        send(test, {:embedding, opts[:receive_timeout]})
        Process.sleep(500)
        {:ok, FakeEmbedder.axis(0)}
      end)

      {micros, result} = :timer.tc(fn -> Search.search(scope, "bees") end)

      assert %{links: [%{id: id}], partial: true} = result
      assert id == link.id
      assert micros < 400_000
      # Its own short timeout, not the embedder's 15 s default.
      assert_received {:embedding, 1_000}

      assert eventually(fn -> Repo.exists?(from c in Call, where: c.user_id == ^scope.user.id) end)
      assert eventually(fn -> match?({:ok, _}, QueryCache.fetch({scope.user.id, AI.embedding_model(), "bees"})) end)

      # The late vector filled the cache: the next search is complete at once.
      assert %{partial: false} = Search.search(scope, "bees")
      assert FakeEmbedder.calls() == 1
    end
  end

  describe "scoping" do
    test "never returns another user's links", %{scope: scope} do
      other = user_scope_fixture()
      link(other, title: "Bees", vector: FakeEmbedder.axis(0))
      mine = link(scope, title: "Bees", vector: FakeEmbedder.axis(0))
      stub_query_vector(FakeEmbedder.axis(0))

      assert [{id, _}] = Search.text_ranks(scope, "bees")
      assert [{^id, _}] = Search.vector_ranks(scope, Pgvector.new(FakeEmbedder.axis(0)))
      assert id == mine.id
      assert ids(Search.search(scope, "bees")) == [mine.id]
    end

    test "a collection limits both lists", %{scope: scope} do
      collection = collection_fixture(scope)
      inside = link(scope, title: "Bees", vector: FakeEmbedder.axis(0))
      outside = link(scope, title: "Bees", vector: FakeEmbedder.axis(0))
      :ok = Acervo.Collections.add_link(scope, collection, inside)
      stub_query_vector(FakeEmbedder.axis(0))

      opts = [collection_id: collection.id]
      assert [{id, _}] = Search.text_ranks(scope, "bees", opts)
      assert [{^id, _}] = Search.vector_ranks(scope, Pgvector.new(FakeEmbedder.axis(0)), opts)
      assert id == inside.id
      assert ids(Search.search(scope, "bees", opts)) == [inside.id]
      assert outside.id in ids(Search.search(scope, "bees"))
    end

    test "another user's collection id finds nothing", %{scope: scope} do
      other = user_scope_fixture()
      theirs = collection_fixture(other)
      their_link = link(other, title: "Bees", vector: FakeEmbedder.axis(0))
      :ok = Acervo.Collections.add_link(other, theirs, their_link)
      link(scope, title: "Bees", vector: FakeEmbedder.axis(0))
      stub_query_vector(FakeEmbedder.axis(0))

      assert %{links: []} = Search.search(scope, "bees", collection_id: theirs.id)
      assert %{links: []} = Search.search(scope, "bees", collection_id: "not-a-uuid")
    end

    test "the collection must be the user's, even if it holds the user's link", %{scope: scope} do
      # Impossible through Collections, so forced: my link in their collection.
      theirs = collection_fixture(user_scope_fixture())
      mine = link(scope, title: "Bees", vector: FakeEmbedder.axis(0))
      Repo.insert!(%CollectionLink{collection_id: theirs.id, link_id: mine.id})
      stub_query_vector(FakeEmbedder.axis(0))

      opts = [collection_id: theirs.id]
      assert Search.text_ranks(scope, "bees", opts) == []
      assert Search.vector_ranks(scope, Pgvector.new(FakeEmbedder.axis(0)), opts) == []
      assert %{links: []} = Search.search(scope, "bees", opts)
    end

    test "filters by source", %{scope: scope} do
      video = link(scope, title: "Bees", source: :youtube, vector: FakeEmbedder.axis(0))
      link(scope, title: "Bees", vector: FakeEmbedder.axis(0))
      stub_query_vector(FakeEmbedder.axis(0))

      assert ids(Search.search(scope, "bees", source: :youtube)) == [video.id]
    end
  end

  describe "embedding model" do
    test "vectors from another model are never compared, while text still finds the link", %{scope: scope} do
      link = link(scope, title: "Bees", vector: FakeEmbedder.axis(0), model: "other:model")
      stub_query_vector(FakeEmbedder.axis(0))

      assert Search.vector_ranks(scope, Pgvector.new(FakeEmbedder.axis(0))) == []
      assert ids(Search.search(scope, "bees")) == [link.id]
    end

    test "a link re-embedding (pending) keeps its current-model vector searchable", %{scope: scope} do
      link = link(scope, title: "Waggle", vector: FakeEmbedder.axis(0), embedding_status: :pending)
      failed = link(scope, title: "Waggle", vector: FakeEmbedder.axis(0), embedding_status: :failed)
      stub_query_vector(FakeEmbedder.axis(0))

      assert link.id in ids(Search.search(scope, "dance"))
      assert failed.id in ids(Search.search(scope, "dance"))
    end

    test "a link still capturing, with no text or vector, is not found", %{scope: scope} do
      capturing = link_fixture(scope)

      refute capturing.id in ids(Search.search(scope, "example"))
    end
  end

  describe "odd and hostile input" do
    @hostile [
      "'); DROP TABLE links; --",
      "'; drop table links; --",
      "\" OR 1=1 --",
      "foo:* & !bar <-> baz",
      "a & | ! ( ) :* <->",
      "\\",
      "%_",
      "\u0000abc",
      "-",
      "or",
      "\"unterminated",
      "🐝🍯 abelhas",
      "مرحبا بالعالم",
      String.duplicate("x", 10_000),
      # unaccent turns these into tsquery syntax (":", "'", "(1)")
      "abcːxyz",
      "ŉabc",
      "⑴abc",
      "ʹʹʹ elixir",
      "dontʼ stop"
    ]

    test "never raises and only returns the scope's links", %{scope: scope} do
      other = user_scope_fixture()
      link(other, title: "drop table links abc or", vector: FakeEmbedder.axis(0))
      mine = link(scope, title: "drop table links abc or", vector: FakeEmbedder.axis(0))
      count = Repo.aggregate(Link, :count)

      for query <- @hostile do
        assert %{links: links, partial: false} = Search.search(scope, query)
        assert Enum.all?(links, &(&1.id == mine.id)), "#{inspect(query)} leaked another user's link"
        assert is_list(Search.text_ranks(scope, Search.normalize_query(query)))
      end

      assert Repo.aggregate(Link, :count) == count
      assert ids(Search.search(scope, "'; drop table links")) == [mine.id]
    end

    test "normalizes the query" do
      assert Search.normalize_query("  bees \u0000 and\t\nhoney\u0085 ") == "bees and honey"
      assert Search.normalize_query("ab" <> <<0xFF>>) == "ab�"
      assert Search.normalize_query(String.duplicate("é", 300)) == String.duplicate("é", 200)
      assert Search.normalize_query(String.duplicate("👩‍👩‍👧", 250)) == String.duplicate("👩‍👩‍👧", 200)
    end
  end

  describe "query cache" do
    test "the same query twice makes one call and one cost record", %{scope: scope} do
      link(scope, title: "Bees", vector: FakeEmbedder.axis(0))

      assert %{partial: false} = Search.search(scope, "bees")
      assert %{partial: false} = Search.search(scope, "  bees ")

      assert FakeEmbedder.calls() == 1
      assert Repo.aggregate(from(c in Call, where: c.user_id == ^scope.user.id), :count) == 1
      assert {:ok, _vector, true} = Search.query_vector(scope, "bees")
    end

    test "another user's same query makes its own call", %{scope: scope} do
      other = user_scope_fixture()

      Search.search(scope, "bees")
      Search.search(other, "bees")

      assert FakeEmbedder.calls() == 2
      assert Repo.aggregate(from(c in Call, where: c.user_id == ^other.user.id), :count) == 1
    end

    test "a failed embedding is not cached", %{scope: scope} do
      FakeEmbedder.stub(fn _model, _text, _opts -> {:error, {:http, 500}} end)
      assert {:error, {:http, 500}} = Search.query_vector(scope, "bees")

      FakeEmbedder.stub(fn _model, text, _opts -> {:ok, FakeEmbedder.vector(text)} end)
      assert {:ok, _vector, false} = Search.query_vector(scope, "bees")
    end
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, tries - 1)
    end
  end
end
