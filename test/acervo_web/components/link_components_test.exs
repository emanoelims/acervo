defmodule AcervoWeb.LinkComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AcervoWeb.LinkComponents

  defp link(attrs) do
    Map.merge(
      %{
        id: "1",
        source: :generic,
        status: :ready,
        title: "A title",
        description: "A description",
        canonical_url: "https://www.example.com/a",
        published_at: nil,
        inserted_at: ~U[2026-01-01 00:00:00Z],
        capture_error: nil,
        images: []
      },
      Map.new(attrs)
    )
  end

  defp image, do: %{id: 7, src: "data:image/png;base64,", width: 16, height: 10}

  defp compact(link), do: render_component(&LinkComponents.card/1, id: "c", link: link, patch: "/x", compact: true)
  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  describe "card/1 compact" do
    test "an image card shows the image and the title, without description, date or source" do
      html = compact(link(images: [image()]))

      assert html |> find("a#c.card.card-compact.card-image[href='/x'] > .thumb > img") |> Enum.count() == 1
      assert html |> find(".ttl") |> LazyHTML.text() |> String.trim() == "A title"
      assert html |> find(".sub, .date, .src, .glow") |> Enum.empty?()
    end

    test "a card without an image shows the title and the host" do
      html = compact(link([]))
      assert html |> find(".card-text .ttl") |> LazyHTML.text() |> String.trim() == "A title"
      assert html |> find(".card-text .host") |> LazyHTML.text() |> String.trim() == "example.com"
      assert html |> find(".thumb") |> Enum.empty?()
    end

    test "a link without a title shows its host once" do
      html = compact(link(title: nil))
      assert html |> find(".ttl") |> LazyHTML.text() |> String.trim() == "example.com"
      assert html |> find(".host") |> Enum.empty?()
    end

    test "a pending link shows the skeleton and its host" do
      html = compact(link(status: :pending))
      assert html |> find(".card-pending > .media.skeleton") |> Enum.count() == 1
      assert html |> find(".ttl") |> LazyHTML.text() |> String.trim() == "example.com"
    end

    test "a video shows its thumbnail with the play mark" do
      html = compact(link(source: :youtube, images: [image()]))
      assert html |> find(".card-video > .thumb > .play") |> Enum.count() == 1
    end

    test "the regular card is unchanged" do
      html = render_component(&LinkComponents.card/1, id: "c", link: link([]), patch: "/x")
      assert html |> find("a#c.card.text:not(.card-compact) .sub") |> LazyHTML.text() |> String.trim() == "A description"
    end
  end
end
