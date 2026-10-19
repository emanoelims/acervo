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

  describe "meta refresh" do
    defp stub_page(refresh) do
      "<html><head><title>Redirecting to: elsewhere</title>#{refresh}</head><body></body></html>"
    end

    defp serve(routes) do
      Req.Test.stub(SafeFetch, fn conn -> html(conn, 200, Map.fetch!(routes, conn.request_path)) end)
    end

    test "follows a refresh to the target page" do
      serve(%{
        "/old" => stub_page(~s(<meta http-equiv="refresh" content="0; url=https://example.com/new">)),
        "/new" => page("article.html")
      })

      assert {:ok, capture, "https://example.com/new"} = Generic.fetch_page(URI.parse("https://example.com/old"), [])
      assert capture.title == "An Article About Bees"
      assert capture.final_url == "https://example.com/new"
    end

    test "resolves a relative target, matching http-equiv case-insensitively" do
      serve(%{
        "/docs/old" => stub_page(~s(<meta HTTP-EQUIV="Refresh" content="0;url=../new/page">)),
        "/new/page" => page("minimal.html")
      })

      assert {:ok, %{title: "Plain Page"}, "https://example.com/new/page"} =
               Generic.fetch_page(URI.parse("https://example.com/docs/old"), [])
    end

    test "accepts a quoted target and a short delay" do
      serve(%{
        "/old" => stub_page(~s(<meta http-equiv="refresh" content="5; URL='/new'">)),
        "/new" => page("minimal.html")
      })

      assert {:ok, %{title: "Plain Page"}, "https://example.com/new"} =
               Generic.fetch_page(URI.parse("https://example.com/old"), [])
    end

    test "does not follow a delay above five seconds" do
      serve(%{"/old" => stub_page(~s(<meta http-equiv="refresh" content="6;url=/new">))})

      assert {:ok, %{title: "Redirecting to: elsewhere"}, "https://example.com/old"} =
               Generic.fetch_page(URI.parse("https://example.com/old"), [])
    end

    test "ignores non-http targets, bare reloads and the page itself" do
      for content <- [
            "0;url=javascript:alert(1)",
            "0;url=data:text/html,hi",
            "0;url=mailto:a@example.com",
            "30",
            "0;url=",
            "0;url=/old",
            "0;url=https://example.com/old#top"
          ] do
        serve(%{"/old" => stub_page(~s(<meta http-equiv="refresh" content="#{content}">))})

        assert {:ok, %{title: "Redirecting to: elsewhere"}, "https://example.com/old"} =
                 Generic.fetch_page(URI.parse("https://example.com/old"), []),
               content
      end
    end

    test "stops after two hops, keeping the last page" do
      serve(%{
        "/a" => stub_page(~s(<meta http-equiv="refresh" content="0;url=/b">)),
        "/b" => stub_page(~s(<meta http-equiv="refresh" content="0;url=/c">)),
        "/c" => stub_page(~s(<meta http-equiv="refresh" content="0;url=/d">))
      })

      assert {:ok, _, "https://example.com/c"} = Generic.fetch_page(URI.parse("https://example.com/a"), [])
    end

    test "a refresh loop is bounded" do
      serve(%{
        "/a" => stub_page(~s(<meta http-equiv="refresh" content="0;url=/b">)),
        "/b" => stub_page(~s(<meta http-equiv="refresh" content="0;url=/a">))
      })

      assert {:ok, _, url} = Generic.fetch_page(URI.parse("https://example.com/a"), [])
      assert url in ["https://example.com/a", "https://example.com/b"]
    end

    test "refuses a target on a private address like any other request" do
      serve(%{"/old" => stub_page(~s(<meta http-equiv="refresh" content="0;url=https://internal.test/admin">))})

      assert {:ok, %{title: "Redirecting to: elsewhere"}, "https://example.com/old"} =
               Generic.fetch_page(URI.parse("https://example.com/old"), [])
    end
  end
end
