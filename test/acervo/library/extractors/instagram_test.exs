defmodule Acervo.Library.Extractors.InstagramTest do
  use ExUnit.Case, async: true

  import Acervo.PageFixtures

  alias Acervo.Library.Extractors.Instagram
  alias Acervo.Library.SafeFetch

  setup {Req.Test, :verify_on_exit!}

  @url "https://www.instagram.com/p/abc/"

  defp html(conn, body), do: conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, body)

  test "extracts open graph data with the facebook user agent" do
    Req.Test.expect(SafeFetch, fn conn ->
      assert Plug.Conn.get_req_header(conn, "user-agent") == ["facebookexternalhit/1.1"]
      html(conn, page("instagram_post.html"))
    end)

    assert {:ok, capture} = Instagram.extract(URI.parse(@url))
    assert capture.title == ~s(Alice on Instagram: "Sunset")
    assert capture.image_urls == ["https://scontent.cdninstagram.com/v/sunset.jpg"]
  end

  test "detects a login wall by title and missing description" do
    Req.Test.expect(SafeFetch, &html(&1, page("instagram_login.html")))
    assert {:error, :blocked} = Instagram.extract(URI.parse(@url))
  end

  test "detects a redirect to the login page" do
    Req.Test.expect(SafeFetch, 2, fn
      %{request_path: "/p/abc/"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://www.instagram.com/accounts/login/?next=/p/abc/")
        |> Plug.Conn.send_resp(302, "")

      conn ->
        html(conn, ~s(<html><head><title>Log in</title><meta name="description" content="x"></head></html>))
    end)

    assert {:error, :blocked} = Instagram.extract(URI.parse(@url))
  end

  test "keeps a page without an image that is not a login wall" do
    Req.Test.expect(SafeFetch, &html(&1, page("minimal.html")))
    assert {:ok, %{title: "Plain Page", image_urls: []}} = Instagram.extract(URI.parse(@url))
  end

  test "match?/1 and error mapping" do
    assert Instagram.match?(URI.parse("https://www.instagram.com/p/x"))
    assert Instagram.match?(URI.parse("https://instagram.com/p/x"))
    refute Instagram.match?(URI.parse("https://example.com"))

    Req.Test.expect(SafeFetch, &Plug.Conn.send_resp(&1, 404, ""))
    assert {:error, :not_found} = Instagram.extract(URI.parse(@url))
  end
end
