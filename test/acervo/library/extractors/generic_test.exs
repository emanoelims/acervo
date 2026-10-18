defmodule Acervo.Library.Extractors.GenericTest do
  use ExUnit.Case, async: true

  import Acervo.PageFixtures

  alias Acervo.Library.Extractors.Generic
  alias Acervo.Library.SafeFetch

  setup {Req.Test, :verify_on_exit!}

  defp html(conn, status, body, type \\ "text/html; charset=utf-8") do
    conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.send_resp(status, body)
  end

  test "extracts an html page, sending the accept header" do
    Req.Test.expect(SafeFetch, fn conn ->
      assert Plug.Conn.get_req_header(conn, "accept") == ["text/html,application/xhtml+xml"]
      assert Plug.Conn.get_req_header(conn, "host") == ["example.com"]
      html(conn, 200, page("article.html"))
    end)

    assert {:ok, capture} = Generic.extract(URI.parse("https://example.com/posts/bees"))
    assert capture.title == "An Article About Bees"
    assert capture.image_urls == ["https://example.com/img/cover.jpg", "https://cdn.example.com/cover-secure.jpg"]
  end

  test "match?/1 accepts everything" do
    assert Generic.match?(URI.parse("https://example.com"))
  end

  test "fetch/2 forwards the user agent" do
    Req.Test.expect(SafeFetch, fn conn ->
      assert Plug.Conn.get_req_header(conn, "user-agent") == ["custom/1.0"]
      html(conn, 200, page("minimal.html"))
    end)

    assert {:ok, %{title: "Plain Page"}} = Generic.fetch(URI.parse("https://example.com/"), user_agent: "custom/1.0")
  end

  test "rejects a response that is not html" do
    Req.Test.expect(SafeFetch, &html(&1, 200, "{}", "application/json"))
    assert {:error, :not_html} = Generic.extract(URI.parse("https://example.com/data"))
  end

  test "maps 404 and 410 to :not_found" do
    Req.Test.expect(SafeFetch, 2, fn
      %{request_path: "/gone"} = conn -> Plug.Conn.send_resp(conn, 410, "")
      conn -> Plug.Conn.send_resp(conn, 404, "")
    end)

    assert {:error, :not_found} = Generic.extract(URI.parse("https://example.com/missing"))
    assert {:error, :not_found} = Generic.extract(URI.parse("https://example.com/gone"))
  end

  test "passes other errors through" do
    Req.Test.expect(SafeFetch, &Plug.Conn.send_resp(&1, 500, ""))
    assert {:error, {:http, 500}} = Generic.extract(URI.parse("https://example.com/boom"))
    assert {:error, :blocked_address} = Generic.extract(URI.parse("https://internal.test/"))
  end
end
