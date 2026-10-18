defmodule Acervo.Library.ExtractorTest do
  use ExUnit.Case, async: true

  import Acervo.PageFixtures

  alias Acervo.Library.Extractor
  alias Acervo.Library.Extractors.Generic
  alias Acervo.Library.Extractors.Instagram
  alias Acervo.Library.Extractors.X
  alias Acervo.Library.Extractors.YouTube

  setup {Req.Test, :verify_on_exit!}

  describe "for/1" do
    test "picks the extractor by host" do
      for {url, module} <- [
            {"https://www.youtube.com/watch?v=abc", YouTube},
            {"https://youtu.be/abc", YouTube},
            {"https://m.youtube.com/watch?v=abc", YouTube},
            {"https://x.com/jack/status/20", X},
            {"https://twitter.com/jack/status/20", X},
            {"https://www.instagram.com/p/abc/", Instagram},
            {"https://example.com/post", Generic}
          ] do
        assert Extractor.for(URI.parse(url)) == module, url
      end
    end
  end

  describe "extract/1" do
    test "dispatches a url string" do
      Req.Test.expect(Acervo.Library.SafeFetch, fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, page("minimal.html"))
      end)

      assert {:ok, %{title: "Plain Page"}} = Extractor.extract("https://example.com/")
    end

    test "rejects an invalid url" do
      assert {:error, :invalid_url} = Extractor.extract("not a url")
    end
  end
end
