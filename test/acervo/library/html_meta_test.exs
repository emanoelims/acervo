defmodule Acervo.Library.HtmlMetaTest do
  use ExUnit.Case, async: true

  import Acervo.PageFixtures

  alias Acervo.Library.Capture
  alias Acervo.Library.HtmlMeta

  @base "https://example.com/posts/bees?x=1"

  test "parses a full article page" do
    assert %Capture{
             title: "An Article About Bees",
             description: "Bees are fascinating.",
             site_name: "Example Journal",
             author: "Jane Roe",
             published_at: ~U[2024-05-01 10:30:00Z],
             canonical_url: "https://example.com/posts/bees",
             image_urls: ["https://example.com/img/cover.jpg", "https://cdn.example.com/cover-secure.jpg"],
             text: text
           } = HtmlMeta.parse(page("article.html"), @base)

    assert text == "Bees Bees pollinate crops."
  end

  test "falls back to title, meta description and main" do
    capture = HtmlMeta.parse(page("minimal.html"), @base)

    assert capture.title == "Plain Page"
    assert capture.description == "Just a description."
    assert capture.text == "Main text here."
    assert capture.image_urls == []
    assert capture.site_name == nil
    assert capture.author == nil
    assert capture.published_at == nil
    assert capture.canonical_url == nil
  end

  test "falls back to twitter tags and article:author" do
    html = """
    <html><head><title>T</title>
    <meta name="twitter:title" content="Tw title">
    <meta name="twitter:description" content="Tw desc">
    <meta property="article:author" content="Bob">
    <meta property="article:published_time" content="not a date">
    </head><body>x</body></html>
    """

    capture = HtmlMeta.parse(html, @base)
    assert capture.title == "Tw title"
    assert capture.description == "Tw desc"
    assert capture.author == "Bob"
    assert capture.published_at == nil
    assert capture.text == "x"
  end

  test "prefers meta author over article:author" do
    html = ~s(<meta name="author" content="A"><meta property="article:author" content="B">)
    assert HtmlMeta.parse(html, @base).author == "A"
  end

  test "deduplicates images and caps them at four" do
    tags = for i <- 1..6, do: ~s(<meta property="og:image" content="/i#{i}.png">)
    dup = ~s(<meta property="og:image" content="/i1.png">)
    capture = HtmlMeta.parse("<html><head>#{dup}#{Enum.join(tags)}</head><body></body></html>", @base)

    assert capture.image_urls == for(i <- 1..4, do: "https://example.com/i#{i}.png")
  end

  test "uses body when there is no article or main, and truncates the text" do
    long = String.duplicate("word ", 3000)
    capture = HtmlMeta.parse("<html><body><nav>skip</nav><div>#{long}</div></body></html>", @base)

    assert String.length(capture.text) in 7999..8000
    assert String.starts_with?(capture.text, "word word")
  end

  test "returns nil text for an empty body" do
    assert HtmlMeta.parse("<html><body></body></html>", @base).text == nil
  end
end
