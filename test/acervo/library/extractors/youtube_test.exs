defmodule Acervo.Library.Extractors.YouTubeTest do
  use ExUnit.Case, async: true

  import Acervo.PageFixtures

  alias Acervo.Library.Extractors.YouTube
  alias Acervo.Library.SafeFetch

  setup {Req.Test, :verify_on_exit!}

  @url "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

  test "builds a capture from oEmbed" do
    Req.Test.expect(SafeFetch, fn conn ->
      assert Plug.Conn.get_req_header(conn, "host") == ["www.youtube.com"]
      assert conn.request_path == "/oembed"
      assert conn.query_string == "url=#{URI.encode_www_form(@url)}&format=json"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, page("youtube_oembed.json"))
    end)

    assert {:ok, capture} = YouTube.extract(URI.parse(@url))
    assert capture.title == "Never Gonna Give You Up"
    assert capture.author == "Rick Astley"
    assert capture.site_name == "YouTube"

    assert capture.image_urls == [
             "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg",
             "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
           ]
  end

  test "reads the id from youtu.be and shorts urls" do
    Req.Test.expect(SafeFetch, 2, &Plug.Conn.send_resp(&1, 200, page("youtube_oembed.json")))

    for url <- ["https://youtu.be/dQw4w9WgXcQ", "https://www.youtube.com/shorts/dQw4w9WgXcQ"] do
      assert {:ok, %{image_urls: ["https://i.ytimg.com/vi/dQw4w9WgXcQ/" <> _ | _]}} = YouTube.extract(URI.parse(url))
    end
  end

  test "match?/1" do
    assert YouTube.match?(URI.parse("https://youtu.be/x"))
    refute YouTube.match?(URI.parse("https://example.com/x"))
  end

  test "maps 404 and 401 to :not_found" do
    Req.Test.expect(SafeFetch, &Plug.Conn.send_resp(&1, 404, ""))
    Req.Test.expect(SafeFetch, &Plug.Conn.send_resp(&1, 401, ""))

    assert {:error, :not_found} = YouTube.extract(URI.parse(@url))
    assert {:error, :not_found} = YouTube.extract(URI.parse(@url))
  end

  test "passes other errors through and rejects a url without an id" do
    Req.Test.expect(SafeFetch, &Plug.Conn.send_resp(&1, 503, ""))
    assert {:error, {:http, 503}} = YouTube.extract(URI.parse(@url))
    assert {:error, :invalid_url} = YouTube.extract(URI.parse("https://www.youtube.com/"))
  end

  test "returns an error for a malformed oEmbed body" do
    Req.Test.expect(SafeFetch, &Plug.Conn.send_resp(&1, 200, "not json"))
    assert {:error, :invalid_response} = YouTube.extract(URI.parse(@url))
  end
end
