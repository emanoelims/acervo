defmodule Acervo.Library.EmbedTest do
  use ExUnit.Case, async: true

  alias Acervo.Library.Embed
  alias Acervo.Library.Link

  doctest Embed

  @youtube "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"

  describe "embed_url/1 for YouTube" do
    test "takes the id from watch, youtu.be and shorts URLs" do
      assert Embed.embed_url("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == {:video, @youtube}
      assert Embed.embed_url("https://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ&t=42") == {:video, @youtube}
      assert Embed.embed_url("https://youtu.be/dQw4w9WgXcQ?si=abc") == {:video, @youtube}
      assert Embed.embed_url("https://www.youtube.com/shorts/dQw4w9WgXcQ") == {:video, @youtube}
      assert Embed.embed_url("https://WWW.YouTube.com/embed/dQw4w9WgXcQ") == {:video, @youtube}
    end

    test "ignores pages that aren't a video, and ids with odd characters" do
      assert Embed.embed_url("https://www.youtube.com/@channel") == nil
      assert Embed.embed_url("https://www.youtube.com/watch") == nil
      assert Embed.embed_url("https://www.youtube.com/watch?v=") == nil
      assert Embed.embed_url("https://www.youtube.com/watch?v=a%22b") == nil
      assert Embed.embed_url("https://www.youtube.com/watch?v=%zz") == nil
    end
  end

  describe "embed_url/1 for X" do
    test "takes the status id from a post URL" do
      embed = {:post, "https://platform.twitter.com/embed/Tweet.html?id=20&dnt=true"}

      assert Embed.embed_url("https://x.com/jack/status/20") == embed
      assert Embed.embed_url("https://twitter.com/jack/status/20/photo/1") == embed
      assert Embed.embed_url("https://x.com/i/web/status/20") == embed
    end

    test "ignores profiles and non-numeric ids" do
      assert Embed.embed_url("https://x.com/jack") == nil
      assert Embed.embed_url("https://x.com/jack/status/abc") == nil
    end
  end

  describe "embed_url/1 for Instagram" do
    test "takes the code from post and reel URLs" do
      embed = {:post, "https://www.instagram.com/p/DAYg2PHyQCu/embed"}

      assert Embed.embed_url("https://www.instagram.com/p/DAYg2PHyQCu") == embed
      assert Embed.embed_url("https://www.instagram.com/reel/DAYg2PHyQCu/") == embed
      assert Embed.embed_url("https://instagram.com/someone/p/DAYg2PHyQCu/") == embed
    end

    test "ignores profiles" do
      assert Embed.embed_url("https://www.instagram.com/someone") == nil
    end
  end

  test "embed_url/1 ignores other sites and non-URLs" do
    assert Embed.embed_url("https://example.com/watch?v=dQw4w9WgXcQ") == nil
    assert Embed.embed_url("ftp://www.youtube.com/watch?v=dQw4w9WgXcQ") == nil
    assert Embed.embed_url(nil) == nil
  end

  describe "frame/1" do
    defp link(attrs), do: struct!(Link, Enum.into(attrs, %{canonical_url: "https://example.com/a", source: :generic}))

    test "embed sources use their embed URL whatever their embeddability" do
      assert Embed.frame(link(canonical_url: "https://x.com/jack/status/20", source: :x, embeddable: false)) ==
               {:embed, :post, "https://platform.twitter.com/embed/Tweet.html?id=20&dnt=true"}
    end

    test "other pages are framed at their resolved URL once found embeddable" do
      assert Embed.frame(link(embeddable: true)) == {:page, "https://example.com/a"}

      assert Embed.frame(link(embeddable: true, resolved_url: "https://example.com/b")) ==
               {:page, "https://example.com/b"}

      assert Embed.frame(link(embeddable: false)) == :blocked
      assert Embed.frame(link(embeddable: nil)) == :unknown
    end

    test "an http URL is never framed" do
      assert Embed.frame(link(embeddable: true, canonical_url: "http://example.com/a")) == :blocked
    end
  end
end
