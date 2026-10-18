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
end
