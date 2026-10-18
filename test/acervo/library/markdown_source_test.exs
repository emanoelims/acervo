defmodule Acervo.Library.MarkdownSourceTest do
  use ExUnit.Case, async: true

  alias Acervo.Library.MarkdownSource
  alias Acervo.Library.SafeFetch

  doctest MarkdownSource

  @markdown "# Bees\n\n" <> String.duplicate("Bees pollinate crops and make honey. ", 10)

  defp doc(head \\ ""), do: LazyHTML.from_document("<html><head>#{head}</head><body><p>Page</p></body></html>")

  # Serves `routes` (path => {content type, body}) and records every request.
  defp stub(routes) do
    test = self()

    Req.Test.stub(SafeFetch, fn conn ->
      send(test, {:requested, conn.request_path})

      case Map.fetch(routes, conn.request_path) do
        {:ok, {type, body}} -> conn |> Plug.Conn.put_resp_content_type(type, nil) |> Plug.Conn.send_resp(200, body)
        :error -> Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  defp requested do
    receive do
      {:requested, path} -> [path | requested()]
    after
      0 -> []
    end
  end

  test "uses the page's alternate Markdown link" do
    stub(%{"/raw/bees.markdown" => {"text/markdown; charset=utf-8", @markdown}})
    head = ~s(<link rel="alternate" type="text/markdown" href="/raw/bees.markdown">)

    assert {:ok, %{markdown: @markdown, url: "https://example.com/raw/bees.markdown"}} =
             MarkdownSource.find(doc(head), "https://example.com/docs/bees")

    assert requested() == ["/raw/bees.markdown"]
  end

  test "tries the page's URL with .md" do
    stub(%{"/docs/bees.md" => {"text/plain", @markdown}})

    assert {:ok, %{url: "https://example.com/docs/bees.md"}} =
             MarkdownSource.find(doc(), "https://example.com/docs/bees.html?ref=x#top")

    stub(%{"/docs/index.md" => {"text/x-markdown", @markdown}})
    assert {:ok, %{url: "https://example.com/docs/index.md"}} = MarkdownSource.find(doc(), "https://example.com/docs/")
  end

  test "follows llms.txt to this page's .md" do
    llms = """
    # Docs

    - [Wasps](https://example.com/md/wasps.md): about wasps
    - [Bees](/md/docs/bees.md): about bees
    """

    stub(%{"/llms.txt" => {"text/plain", llms}, "/md/docs/bees.md" => {"text/markdown", @markdown}})

    assert {:ok, %{url: "https://example.com/md/docs/bees.md"}} =
             MarkdownSource.find(doc(), "https://example.com/md/docs/bees/")

    assert requested() == ["/md/docs/bees/index.md", "/llms.txt", "/md/docs/bees.md"]
  end

  test "ignores llms.txt without a link to this page" do
    llms = "# Docs\n\n- [Wasps](/wasps.md)\n- [Elsewhere](https://other.test/bees.md)\n" <> String.duplicate(" ", 200)
    stub(%{"/llms.txt" => {"text/plain", llms}, "/wasps.md" => {"text/markdown", @markdown}})

    assert MarkdownSource.find(doc(), "https://example.com/bees") == :none
    assert requested() == ["/bees.md", "/llms.txt"]
  end

  test "rejects HTML, other content types and short bodies" do
    for {type, body} <- [
          {"text/plain", "<!DOCTYPE html><html><body>" <> @markdown <> "</body></html>"},
          {"text/plain", "\n  <html>" <> @markdown},
          {"text/html", @markdown},
          {"application/octet-stream", @markdown},
          {"text/markdown", "# Not found"}
        ] do
      stub(%{"/bees.md" => {type, body}})
      assert MarkdownSource.find(doc(), "https://example.com/bees") == :none, inspect({type, body})
    end
  end

  test "makes at most three requests" do
    head = ~s(<link rel="alternate" type="text/markdown" href="/alt.md">)
    stub(%{"/llms.txt" => {"text/plain", "- [Bees](/bees/index.md)" <> String.duplicate(" ", 200)}})

    assert MarkdownSource.find(doc(head), "https://example.com/bees") == :none
    assert requested() == ["/alt.md", "/bees.md"]
  end

  test "stops when the deadline is near" do
    stub(%{"/bees.md" => {"text/markdown", @markdown}})
    deadline = System.monotonic_time(:millisecond)

    assert MarkdownSource.find(doc(), "https://example.com/bees", deadline: deadline) == :none
    assert requested() == []
  end

  test "llms_match/3 matches the page's path with or without .html or index" do
    page = URI.parse("https://example.com/guide/start.html")
    body = "[Start](/guide/start.md) [Other](/guide/other.md)"
    assert MarkdownSource.llms_match(body, "https://example.com/llms.txt", page) == "https://example.com/guide/start.md"

    page = URI.parse("https://example.com/guide/")
    body = ~s|[Guide](https://example.com/guide/index.md "Guide")|
    assert MarkdownSource.llms_match(body, "https://example.com/llms.txt", page) == "https://example.com/guide/index.md"

    assert MarkdownSource.llms_match("[x](javascript:alert(1))", "https://example.com/llms.txt", page) == nil
  end
end
