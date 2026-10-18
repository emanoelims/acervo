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

  test "keeps only http(s) images and they do not consume the cap" do
    tags =
      for u <- ["data:image/png;base64,AAAA", "javascript:alert(1)", "ftp://example.com/a.png", "/ok.png"],
          do: ~s(<meta property="og:image" content="#{u}">)

    capture = HtmlMeta.parse("<html><head>#{Enum.join(tags)}</head><body></body></html>", @base)
    assert capture.image_urls == ["https://example.com/ok.png"]
  end

  test "decodes a Latin-1 body using the content-type charset" do
    html = :unicode.characters_to_binary("<html><head><title>ação</title></head><body></body></html>", :utf8, :latin1)
    assert HtmlMeta.parse(html, @base, "text/html; charset=iso-8859-1").title == "ação"
  end

  test "decodes a Latin-1 body using meta charset" do
    html =
      :unicode.characters_to_binary(
        ~s(<html><head><meta charset="ISO-8859-1"><title>ação</title></head></html>),
        :utf8,
        :latin1
      )

    assert HtmlMeta.parse(html, @base).title == "ação"
  end

  test "never returns invalid UTF-8" do
    capture = HtmlMeta.parse(<<"<html><head><title>a", 0xFF, "b</title></head><body>x", 0xFE, "y</body></html>">>, @base)
    assert String.valid?(capture.title)
    assert String.valid?(capture.text)
  end

  test "falls through an empty article to main" do
    long = String.duplicate("main text ", 40)
    capture = HtmlMeta.parse("<html><body><article></article><main>#{long}</main></body></html>", @base)
    assert capture.text =~ "main text main text"
  end

  test "uses the longest candidate when none reaches the minimum" do
    capture = HtmlMeta.parse("<html><body><article>short</article><main></main></body></html>", @base)
    assert capture.text == "short"
  end

  test "block tags separate text and inline tags do not" do
    capture = HtmlMeta.parse("<html><body><p>foo<b>bar</b></p><p>a</p><p>b<br>c</p></body></html>", @base)
    assert capture.text == "foobar a b c"
  end

  test "plain_text/1 turns br into a separator" do
    lazy = LazyHTML.from_fragment("<blockquote><p>line one<br>line two</p></blockquote>")
    assert HtmlMeta.plain_text(LazyHTML.query(lazy, "blockquote p")) == "line one line two"
  end
end
