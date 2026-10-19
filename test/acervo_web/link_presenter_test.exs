defmodule AcervoWeb.LinkPresenterTest do
  use ExUnit.Case, async: true

  alias Acervo.Collections.Collection
  alias Acervo.Collections.Suggestion
  alias Acervo.Library.Link
  alias AcervoWeb.LinkPresenter

  doctest LinkPresenter

  defp link(attrs) do
    struct!(
      %Link{
        canonical_url: "https://www.example.com/post",
        source: :generic,
        status: :ready,
        images: [],
        inserted_at: ~U[2026-10-01 12:00:00Z]
      },
      attrs
    )
  end

  describe "titles" do
    test "display_title/1 prefers the title, then the host" do
      assert LinkPresenter.display_title(link(title: "A post")) == "A post"
      assert LinkPresenter.display_title(link(title: nil)) == "example.com"
    end

    test "site_title/1 prefers the site name, then the display title" do
      assert LinkPresenter.site_title(link(site_name: "Example", title: "A post")) == "Example"
      assert LinkPresenter.site_title(link(site_name: "", title: "A post")) == "A post"
    end

    test "host/1 keeps a URL without a host as it is" do
      assert LinkPresenter.host(link(canonical_url: "not a url")) == "not a url"
      assert LinkPresenter.host(link(canonical_url: "https://sub.example.com")) == "sub.example.com"
    end
  end

  test "link_date/1 falls back to when the link was saved" do
    assert LinkPresenter.link_date(link(published_at: ~U[2026-09-01 00:00:00Z])) == ~U[2026-09-01 00:00:00Z]
    assert LinkPresenter.link_date(link(published_at: nil)) == ~U[2026-10-01 12:00:00Z]
  end

  describe "kind/1 and first_image/1" do
    test "a link being captured is pending, whatever it has" do
      assert LinkPresenter.kind(link(status: :pending, images: [%{id: 1}])) == :pending
      assert LinkPresenter.kind(link(status: :processing)) == :pending
    end

    test "after capture: text without images, video for YouTube, image otherwise" do
      assert LinkPresenter.kind(link(status: :failed)) == :text
      assert LinkPresenter.kind(link(source: :youtube, images: [%{id: 1}])) == :video
      assert LinkPresenter.kind(link(source: :x, images: [%{id: 1}])) == :image
    end

    test "first_image/1 is the first image or nil" do
      assert LinkPresenter.first_image(link(images: [%{id: 1}, %{id: 2}])) == %{id: 1}
      assert LinkPresenter.first_image(link(images: [])) == nil
    end
  end

  test "meta/1 joins author, site or host and date, leaving blanks out" do
    Gettext.put_locale(AcervoWeb.Gettext, "en")

    assert LinkPresenter.meta(link(author: "Ana", site_name: "Example", published_at: ~U[2026-10-12 00:00:00Z])) ==
             "Ana · Example · Oct 12, 2026"

    assert LinkPresenter.meta(link(author: "", site_name: nil)) == "example.com · Oct 1, 2026"
  end

  test "suggestion_name/1 names the collection or the proposal" do
    assert LinkPresenter.suggestion_name(%Suggestion{collection: %Collection{name: "Design"}}) == "Design"
    assert LinkPresenter.suggestion_name(%Suggestion{collection: nil, proposed_name: "Type"}) == "Type"
  end

  test "paragraphs/1 groups sentences into paragraphs of about 480 characters" do
    sentence = String.duplicate("word ", 30) <> "end."
    [first, second] = LinkPresenter.paragraphs(Enum.join(List.duplicate(sentence, 5), " "))

    assert byte_size(first) >= 480
    assert String.ends_with?(second, "end.")
  end

  describe "collection_choices/2" do
    setup do
      %{
        collections: [
          %Collection{id: 1, name: "Café", slug: "cafe"},
          %Collection{id: 2, name: "C", slug: "c"},
          %Collection{id: 3, name: "Design", slug: "design"}
        ]
      }
    end

    test "an empty query lists every collection and creates nothing", %{collections: collections} do
      assert %{options: ^collections, create?: false, query: ""} = LinkPresenter.collection_choices(collections, nil)
    end

    test "matching ignores accents and case", %{collections: collections} do
      assert %{options: [%{id: 1}], create?: false} = LinkPresenter.collection_choices(collections, " CAFE ")
    end

    test "a query that takes an existing slug offers that collection", %{collections: collections} do
      assert %{options: [%{id: 2}], create?: false, query: "C++"} =
               LinkPresenter.collection_choices(collections, "C++")
    end

    test "a new name is offered for creation", %{collections: collections} do
      assert %{options: [], create?: true, query: "Type"} = LinkPresenter.collection_choices(collections, "Type")
    end
  end
end
