defmodule Acervo.Library.URLTest do
  use ExUnit.Case, async: true

  alias Acervo.Library.Extractor
  alias Acervo.Library.Extractors.YouTube
  alias Acervo.Library.URL

  describe "normalize/1" do
    for {input, expected} <- [
          {"https://Example.com/Page/?utm_source=x&id=3#top", "https://example.com/Page?id=3"},
          {"example.com", "https://example.com/"},
          {"  example.com/page  ", "https://example.com/page"},
          {"http://example.com:80/a/", "http://example.com/a"},
          {"https://example.com:443/a", "https://example.com/a"},
          {"https://example.com:8443/a", "https://example.com:8443/a"},
          {"https://user:pass@example.com/a", "https://example.com/a"},
          {"http://localhost:4000/a/", "http://localhost:4000/a"},
          {"https://www.example.com/a", "https://www.example.com/a"},
          {"https://example.com/a?fbclid=1&b=2&gclid=3&a=1&mc_eid=4", "https://example.com/a?b=2&a=1"},
          {"https://example.com/a?utm_source=x&utm_medium=y", "https://example.com/a"},
          {"https://example.com/a?t=1&s=2", "https://example.com/a?t=1&s=2"},
          {"https://youtu.be/dQw4w9WgXcQ?si=abc", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
          {"https://m.youtube.com/watch?v=dQw4w9WgXcQ&feature=share&t=10", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
          {"https://www.youtube.com/shorts/abc123", "https://www.youtube.com/watch?v=abc123"},
          {"https://youtube.com/watch?list=x&v=abc&pp=zz", "https://www.youtube.com/watch?v=abc"},
          {"https://twitter.com/user/status/1?s=20&t=xyz", "https://x.com/user/status/1"},
          {"https://mobile.twitter.com/user/status/1", "https://x.com/user/status/1"},
          {"https://www.x.com/user/", "https://x.com/user"},
          {"https://instagram.com/p/Cx1/?igsh=abc&img_index=1", "https://www.instagram.com/p/Cx1"}
        ] do
      test "normalizes #{input}" do
        assert {:ok, unquote(expected)} = URL.normalize(unquote(input))
      end
    end

    for input <- ["", "   ", "ftp://x.com", "javascript:alert(1)", "not a url", "http://", "https://nodot"] do
      test "rejects #{inspect(input)}" do
        assert {:error, :invalid_url} = URL.normalize(unquote(input))
      end
    end
  end

  describe "source/1" do
    test "detects each provider from a canonical URL" do
      assert URL.source("https://www.youtube.com/watch?v=abc") == :youtube
      assert URL.source("https://www.instagram.com/p/Cx1") == :instagram
      assert URL.source("https://x.com/user/status/1") == :x
      assert URL.source("https://example.com/") == :generic
      assert URL.source("garbage") == :generic
    end

    test "treats YouTube Music as YouTube, like the extractor" do
      {:ok, url} = URL.normalize("https://music.youtube.com/watch?v=abc&si=x")

      assert url == "https://music.youtube.com/watch?v=abc"
      assert URL.source(url) == :youtube
      assert Extractor.for(URI.parse(url)) == YouTube
    end
  end

  describe "extract_all/1" do
    test "reads a list copied from notes, one per line" do
      text = """
      Read later:
      - https://elixir-lang.org/blog/
      - https://hexdocs.pm/phoenix_live_view/welcome.html
        * www.example.com/notes
      https://fly.io/docs/
      """

      assert URL.extract_all(text) == [
               "https://elixir-lang.org/blog/",
               "https://hexdocs.pm/phoenix_live_view/welcome.html",
               "www.example.com/notes",
               "https://fly.io/docs/"
             ]
    end

    test "finds links inside a chat message, without the punctuation around them" do
      text =
        "hey, did you see this? https://example.com/a-post. And (https://example.com/b), " <>
          "also \"https://example.com/c\"! last one: <https://example.com/d>, ok?"

      assert URL.extract_all(text) == [
               "https://example.com/a-post",
               "https://example.com/b",
               "https://example.com/c",
               "https://example.com/d"
             ]
    end

    test "splits links separated by commas, with or without a space" do
      assert URL.extract_all("https://a.com/1,https://b.com/2, https://c.com/3,www.d.com") ==
               ["https://a.com/1", "https://b.com/2", "https://c.com/3", "www.d.com"]
    end

    test "keeps commas, queries and fragments inside a link" do
      assert URL.extract_all("see https://example.com/a,b?ids=1,2&q=x#top.") ==
               ["https://example.com/a,b?ids=1,2&q=x#top"]
    end

    test "reads markdown links and bare links in markdown" do
      text = """
      ## Links
      - [Phoenix](https://www.phoenixframework.org/) is **great**
      - [https://hexdocs.pm/ecto](https://hexdocs.pm/ecto)
      - **https://example.com/bold**
      - [titled](https://example.com/titled "The title")
      """

      assert URL.extract_all(text) == [
               "https://www.phoenixframework.org/",
               "https://hexdocs.pm/ecto",
               "https://example.com/bold",
               "https://example.com/titled"
             ]
    end

    test "lists a link once, comparing canonical forms" do
      text = """
      https://example.com/a?utm_source=news
      https://Example.com/a/
      https://youtu.be/dQw4w9WgXcQ
      https://www.youtube.com/watch?v=dQw4w9WgXcQ&feature=share
      https://twitter.com/jack/status/20 and https://x.com/jack/status/20
      """

      assert URL.extract_all(text) == [
               "https://example.com/a?utm_source=news",
               "https://youtu.be/dQw4w9WgXcQ",
               "https://twitter.com/jack/status/20"
             ]
    end

    test "returns at most 50 links" do
      text = Enum.map_join(1..60, "\n", &"https://example.com/#{&1}")

      urls = URL.extract_all(text)

      assert length(urls) == 50
      assert List.first(urls) == "https://example.com/1"
      assert List.last(urls) == "https://example.com/50"
    end

    test "counts duplicates once toward the cap" do
      text = String.duplicate("https://example.com/same ", 60) <> "https://example.com/other"

      assert URL.extract_all(text) == ["https://example.com/same", "https://example.com/other"]
    end

    test "ignores other schemes" do
      text = """
      [click](javascript:alert(1)) javascript:https://evil.example.com
      ftp://example.com/file mailto:me@example.com data:text/html,hi
      file:///etc/passwd me@www.example.com
      """

      assert URL.extract_all(text) == []
    end

    test "keeps Wikipedia's balanced parentheses" do
      text = """
      https://en.wikipedia.org/wiki/Elixir_(programming_language)
      (see https://en.wikipedia.org/wiki/Erlang_(programming_language))
      [BEAM](https://en.wikipedia.org/wiki/BEAM_(Erlang_virtual_machine)).
      """

      assert URL.extract_all(text) == [
               "https://en.wikipedia.org/wiki/Elixir_(programming_language)",
               "https://en.wikipedia.org/wiki/Erlang_(programming_language)",
               "https://en.wikipedia.org/wiki/BEAM_(Erlang_virtual_machine)"
             ]
    end

    test "keeps links that don't normalize, so they count as invalid" do
      assert URL.extract_all("https://nodot and https://example.com") == ["https://nodot", "https://example.com"]
    end

    test "returns nothing for text without links" do
      assert URL.extract_all("") == []
      assert URL.extract_all("just some words, and example.com") == []
      assert URL.extract_all("https:// and www. alone") == []
    end
  end
end
