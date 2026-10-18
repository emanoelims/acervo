defmodule Acervo.Library.LinkTest do
  use Acervo.DataCase, async: true

  import Acervo.AccountsFixtures

  alias Acervo.Library.Link

  @valid %{url: "https://example.com/a?utm=1", canonical_url: "https://example.com/a", source: :generic}

  describe "create_changeset/2" do
    test "is valid with url, canonical_url and source" do
      assert %{valid?: true} = Link.create_changeset(%Link{}, @valid)
    end

    test "requires url, canonical_url and source" do
      changeset = Link.create_changeset(%Link{}, %{})

      assert %{url: ["can't be blank"], canonical_url: ["can't be blank"], source: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "limits url and canonical_url to 2048 characters" do
      long = "https://example.com/" <> String.duplicate("a", 2048)
      errors = errors_on(Link.create_changeset(%Link{}, %{@valid | url: long, canonical_url: long}))

      assert [_] = errors.url
      assert [_] = errors.canonical_url
    end

    test "rejects an unknown source" do
      assert %{source: ["is invalid"]} = errors_on(Link.create_changeset(%Link{}, %{@valid | source: :nope}))
    end

    test "defaults status to pending" do
      assert %Link{status: :pending} = %Link{}
    end

    test "does not cast capture fields" do
      changeset = Link.create_changeset(%Link{}, Map.put(@valid, :title, "x"))
      refute Map.has_key?(changeset.changes, :title)
    end

    test "reports a duplicate canonical_url for the same user" do
      user = user_fixture()
      assert {:ok, _} = %Link{user_id: user.id} |> Link.create_changeset(@valid) |> Repo.insert()

      assert {:error, changeset} = %Link{user_id: user.id} |> Link.create_changeset(@valid) |> Repo.insert()
      assert %{canonical_url: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows the same canonical_url for another user" do
      one = user_fixture()
      two = user_fixture()
      assert {:ok, _} = %Link{user_id: one.id} |> Link.create_changeset(@valid) |> Repo.insert()
      assert {:ok, _} = %Link{user_id: two.id} |> Link.create_changeset(@valid) |> Repo.insert()
    end
  end

  describe "capture_changeset/2" do
    test "casts content, status and capture_error" do
      changeset =
        Link.capture_changeset(%Link{}, %{
          title: "T",
          description: "D",
          author: "A",
          site_name: "S",
          published_at: ~U[2026-01-01 00:00:00Z],
          text_excerpt: "text",
          status: :ready,
          capture_error: "boom"
        })

      assert changeset.valid?
      assert changeset.changes.status == :ready
      assert changeset.changes.title == "T"
    end

    test "truncates text_excerpt to 8000 characters" do
      changeset = Link.capture_changeset(%Link{}, %{text_excerpt: String.duplicate("a", 8001)})
      assert changeset.valid?
      assert String.length(changeset.changes.text_excerpt) == 8000
    end

    test "stores long captured values truncated without raising" do
      user = user_fixture()
      {:ok, link} = %Link{user_id: user.id} |> Link.create_changeset(@valid) |> Repo.insert()

      attrs = %{title: String.duplicate("t", 10_000), author: String.duplicate("a", 1_000)}
      assert {:ok, saved} = link |> Link.capture_changeset(attrs) |> Repo.update()
      saved = Repo.reload!(saved)

      assert String.length(saved.title) == 500
      assert String.length(saved.author) == 200
    end

    test "inserts a link with long captured values truncated" do
      user = user_fixture()
      attrs = Map.merge(@valid, %{title: String.duplicate("t", 10_000), author: String.duplicate("a", 1_000)})

      assert {:ok, saved} =
               %Link{user_id: user.id}
               |> Link.create_changeset(@valid)
               |> Link.capture_changeset(attrs)
               |> Repo.insert()

      assert String.length(saved.title) == 500
      assert String.length(saved.author) == 200
    end

    test "does not cast url" do
      changeset = Link.capture_changeset(%Link{}, %{url: "https://x.test"})
      refute Map.has_key?(changeset.changes, :url)
    end
  end

  describe "note_changeset/2" do
    test "casts the note" do
      assert %{changes: %{note: "hi"}} = Link.note_changeset(%Link{}, %{note: "hi"})
    end

    test "limits the note to 4000 characters" do
      changeset = Link.note_changeset(%Link{}, %{note: String.duplicate("a", 4001)})
      assert [_] = errors_on(changeset).note
    end
  end

  describe "enrichment_changeset/2" do
    test "casts the enrichment fields" do
      now = DateTime.utc_now(:second)

      changeset =
        Link.enrichment_changeset(%Link{}, %{
          image_description: "A red square",
          language: "pt",
          enrichment_status: :ready,
          enriched_at: now
        })

      assert changeset.valid?

      assert %{image_description: "A red square", language: "pt", enrichment_status: :ready, enriched_at: ^now} =
               changeset.changes
    end

    test "clips the description to 1000 characters and strips NUL bytes" do
      changeset = Link.enrichment_changeset(%Link{}, %{image_description: "a" <> <<0>> <> String.duplicate("b", 2000)})

      description = Ecto.Changeset.get_change(changeset, :image_description)
      assert String.length(description) == 1000
      refute description =~ <<0>>
    end

    test "accepts language tags and rejects anything else" do
      for language <- ~w(pt en pt-BR zh-Hant) do
        assert Link.enrichment_changeset(%Link{}, %{language: language}).valid?, language
      end

      for language <- ["português", "x", "PT", "pt_BR", "en-", "pt-BR-x"] do
        assert %{language: [_]} = errors_on(Link.enrichment_changeset(%Link{}, %{language: language})), language
      end
    end

    test "clips the language to 16 characters before validating it" do
      changeset = Link.enrichment_changeset(%Link{}, %{language: String.duplicate("a", 40)})
      assert String.length(Ecto.Changeset.get_change(changeset, :language)) == 16
      refute changeset.valid?
    end

    test "rejects an unknown enrichment status" do
      assert %{enrichment_status: ["is invalid"]} =
               errors_on(Link.enrichment_changeset(%Link{}, %{enrichment_status: :done}))
    end
  end

  describe "image_description_changeset/2" do
    test "trims the description and stamps the edit" do
      changeset = Link.image_description_changeset(%Link{}, %{image_description: "  A red square  "})

      assert changeset.changes.image_description == "A red square"
      assert %DateTime{} = changeset.changes.image_description_edited_at
    end

    test "turns a blank description into nil" do
      changeset = Link.image_description_changeset(%Link{image_description: "old"}, %{image_description: "   "})

      assert Map.fetch(changeset.changes, :image_description) == {:ok, nil}
      assert %DateTime{} = changeset.changes.image_description_edited_at
    end

    test "does not stamp the edit when the description is unchanged" do
      link = %Link{image_description: "same"}

      assert Link.image_description_changeset(link, %{image_description: " same "}).changes == %{}
      assert Link.image_description_changeset(%Link{}, %{image_description: ""}).changes == %{}
    end

    test "limits the description to 1000 characters" do
      changeset = Link.image_description_changeset(%Link{}, %{image_description: String.duplicate("a", 1001)})
      assert [_] = errors_on(changeset).image_description
    end

    test "casts nothing else" do
      changeset = Link.image_description_changeset(%Link{}, %{image_description: "x", language: "pt", note: "n"})
      assert Map.keys(changeset.changes) -- [:image_description, :image_description_edited_at] == []
    end
  end
end
