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
end
