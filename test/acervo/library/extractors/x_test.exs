defmodule Acervo.Library.Extractors.XTest do
  use ExUnit.Case, async: true

  import Acervo.PageFixtures

  alias Acervo.Library.Extractors.X
  alias Acervo.Library.SafeFetch

  setup {Req.Test, :verify_on_exit!}

  @url "https://x.com/jack/status/20"

  defp stub(page_status, page_body \\ "") do
    Req.Test.expect(SafeFetch, 2, fn
      %{request_path: "/oembed"} = conn ->
        assert conn.query_string == "url=#{URI.encode_www_form(@url)}&omit_script=true"
        assert Plug.Conn.get_req_header(conn, "host") == ["publish.twitter.com"]
        Plug.Conn.send_resp(conn, 200, page("x_oembed.json"))

      conn ->
        assert Plug.Conn.get_req_header(conn, "host") == ["x.com"]

        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(page_status, page_body)
    end)
  end

  test "builds a capture from oEmbed and takes images from the page" do
    stub(200, page("x_page.html"))

    assert {:ok, capture} = X.extract(URI.parse(@url))
    assert capture.title == "jack on X"
    assert capture.author == "jack"
    assert capture.site_name == "X"
    assert capture.text == "just setting up my twttr"
    assert capture.image_urls == ["https://pbs.twimg.com/media/abc.jpg"]
  end

  test "ignores a failing page fetch" do
    stub(403)

    assert {:ok, %{text: "just setting up my twttr", image_urls: []}} = X.extract(URI.parse(@url))
  end

  test "match?/1" do
    assert X.match?(URI.parse("https://x.com/a"))
    assert X.match?(URI.parse("https://twitter.com/a"))
    refute X.match?(URI.parse("https://example.com/a"))
  end

  test "maps an oEmbed 404 to :not_found" do
    Req.Test.expect(SafeFetch, &Plug.Conn.send_resp(&1, 404, ""))
    assert {:error, :not_found} = X.extract(URI.parse(@url))
  end

  test "passes other oEmbed errors through" do
    Req.Test.expect(SafeFetch, &Plug.Conn.send_resp(&1, 500, ""))
    assert {:error, {:http, 500}} = X.extract(URI.parse(@url))
  end
end
