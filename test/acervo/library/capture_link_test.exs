defmodule Acervo.Library.CaptureLinkTest do
  use Acervo.DataCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures
  import ExUnit.CaptureLog

  alias Acervo.AI.EnrichLink
  alias Acervo.Library
  alias Acervo.Library.CaptureLink
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage
  alias Acervo.Library.SafeFetch

  setup do
    scope = user_scope_fixture()
    Library.subscribe(scope)
    %{scope: scope}
  end

  defp page_html(image_paths, canonical \\ nil) do
    images = Enum.map_join(image_paths, "\n", &~s(<meta property="og:image" content="#{&1}">))
    canonical = if canonical, do: ~s(<link rel="canonical" href="#{canonical}">), else: ""

    """
    <!doctype html>
    <html><head>
    <meta property="og:title" content="Bees">
    <meta property="og:description" content="All about bees.">
    <meta property="og:site_name" content="Example Journal">
    <meta name="author" content="Jane Roe">
    <meta property="article:published_time" content="2024-05-01T10:30:00Z">
    #{images}
    #{canonical}
    </head><body><article><p>Bees pollinate crops.</p></article></body></html>
    """
  end

  defp stub_site(html, images) do
    Req.Test.stub(SafeFetch, fn conn ->
      case Map.fetch(images, conn.request_path) do
        {:ok, bytes} ->
          conn |> Plug.Conn.put_resp_content_type("image/png", nil) |> Plug.Conn.send_resp(200, bytes)

        :error when conn.request_path == "/posts/bees" ->
          conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, html)

        :error ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  defp distinct_png(size) do
    size |> Image.new!(size, color: :red) |> Image.write!(:memory, suffix: ".png")
  end

  defp images_of(link) do
    Repo.all(from i in LinkImage, where: i.link_id == ^link.id, order_by: i.position)
  end

  defp perform(link, opts \\ []), do: perform_job(CaptureLink, %{"link_id" => link.id}, opts)

  describe "success" do
    test "stores preview images as WebP and fills the fields", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/bees?utm_source=feed")

      stub_site(
        page_html(["/img/a.jpg", "/img/missing.jpg", "/img/b.png"], "https://example.com/posts/bees-canonical"),
        %{"/img/a.jpg" => image_fixture("photo.jpg"), "/img/b.png" => image_fixture("wide.png")}
      )

      assert :ok = perform(link)

      link = Repo.get!(Link, link.id)
      assert link.status == :ready
      assert link.capture_error == nil
      assert link.title == "Bees"
      assert link.description == "All about bees."
      assert link.site_name == "Example Journal"
      assert link.author == "Jane Roe"
      assert link.published_at == ~U[2024-05-01 10:30:00Z]
      assert link.text_excerpt =~ "Bees pollinate crops."
      assert link.canonical_url == "https://example.com/posts/bees"
      assert link.resolved_url == "https://example.com/posts/bees-canonical"

      assert [%LinkImage{position: 0} = first, %LinkImage{position: 1}] = images_of(link)
      assert first.kind == :preview
      assert first.content_type == "image/webp"
      assert <<"RIFF", _::binary-size(4), "WEBP", _::binary>> = first.bytes

      assert_receive {:link_updated, %Link{status: :ready, images: [_, _]}}
    end

    test "stores whether the page allows framing", %{scope: scope} do
      open = link_fixture(scope, "https://example.com/posts/bees")
      stub_site(page_html([]), %{})

      assert :ok = perform(open)
      assert %Link{embeddable: true} = Repo.get!(Link, open.id)

      framed_only_by_itself = link_fixture(scope, "https://example.com/posts/wasps")

      Req.Test.stub(SafeFetch, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-security-policy", "default-src 'self'; frame-ancestors 'self'")
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, page_html([]))
      end)

      assert :ok = perform(framed_only_by_itself)
      assert %Link{embeddable: false} = Repo.get!(Link, framed_only_by_itself.id)
    end

    test "a page answered with X-Frame-Options or over http is not embeddable", %{scope: scope} do
      denied = link_fixture(scope, "https://example.com/posts/bees")

      Req.Test.stub(SafeFetch, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-frame-options", "DENY")
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, page_html([]))
      end)

      assert :ok = perform(denied)
      assert %Link{embeddable: false} = Repo.get!(Link, denied.id)

      plain = link_fixture(scope, "http://example.com/posts/bees")
      stub_site(page_html([]), %{})

      assert :ok = perform(plain)
      assert %Link{embeddable: false} = Repo.get!(Link, plain.id)
    end

    test "stores at most four images", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/bees")
      paths = for i <- 1..6, do: "/img/#{i}.png"
      stub_site(page_html(paths), Map.new(Enum.with_index(paths, 1), fn {p, i} -> {p, distinct_png(10 + i)} end))

      assert :ok = perform(link)
      assert [0, 1, 2, 3] = link |> images_of() |> Enum.map(& &1.position)
    end

    test "a re-capture does not duplicate images", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/bees")
      stub_site(page_html(["/img/a.jpg"]), %{"/img/a.jpg" => image_fixture("photo.jpg")})

      assert :ok = perform(link)
      assert :ok = perform(link)
      assert [_] = images_of(link)
    end

    test "records the page's canonical url even when another link has it", %{scope: scope} do
      _taken = link_fixture(scope, "https://example.com/taken")
      link = link_fixture(scope, "https://example.com/posts/bees")
      stub_site(page_html([], "https://example.com/taken"), %{})

      assert :ok = perform(link)

      assert %Link{
               status: :ready,
               canonical_url: "https://example.com/posts/bees",
               resolved_url: "https://example.com/taken"
             } =
               Repo.get!(Link, link.id)
    end

    test "records the final url after redirects when the page has no canonical url", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/old")

      Req.Test.stub(SafeFetch, fn
        %{request_path: "/old"} = conn ->
          conn |> Plug.Conn.put_resp_header("location", "/posts/bees") |> Plug.Conn.send_resp(301, "")

        conn ->
          conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, page_html([]))
      end)

      assert :ok = perform(link)

      assert %Link{canonical_url: "https://example.com/old", resolved_url: "https://example.com/posts/bees"} =
               Repo.get!(Link, link.id)
    end

    test "ignores a canonical url that is not http(s) or too long", %{scope: scope} do
      for canonical <- ["ftp://example.com/bees", "https://example.com/" <> String.duplicate("a", 2048)] do
        link = link_fixture(scope, "https://example.com/posts/bees?v=#{System.unique_integer([:positive])}")
        stub_site(page_html([], canonical), %{})

        assert :ok = perform(link)
        assert Repo.get!(Link, link.id).resolved_url == link.canonical_url
      end
    end

    test "a link left processing by a killed run is captured on retry", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/bees")
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [status: :processing])
      stub_site(page_html([]), %{})

      assert :ok = perform(link, attempt: 2)
      assert %Link{status: :ready, title: "Bees"} = Repo.get!(Link, link.id)
    end
  end

  describe "reader view" do
    defp article_html do
      paragraphs = Enum.map_join(1..3, "\n", &"<p>Paragraph #{&1}: bees pollinate crops and make honey for the hive.</p>")

      """
      <!doctype html>
      <html><head><meta property="og:title" content="Bees"></head>
      <body><nav><a href="/">Home</a></nav>
      <article><h1>Bees</h1>#{paragraphs}
      <p><img src="/img/hive.png" alt="Hive"><img src="/img/missing.png"><img src="/img/tiny.png"></p>
      <p><a href="javascript:alert(1)" onclick="x">trap</a></p>
      </article></body></html>
      """
    end

    defp reader_link(link),
      do:
        Repo.one!(
          from l in Link,
            where: l.id == ^link.id,
            select: map(l, [:content_html, :content_source, :content_extracted_at, :title])
        )

    defp content_images(link), do: link |> images_of() |> Enum.filter(&(&1.kind == :content))

    test "stores the article as sanitized HTML with its images", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/bees")
      stub_site(article_html(), %{"/img/hive.png" => distinct_png(40), "/img/tiny.png" => distinct_png(8)})

      assert :ok = perform(link)

      assert %{content_source: :html, content_html: html, content_extracted_at: %DateTime{}} = reader_link(link)
      assert [%LinkImage{kind: :content, width: 40, height: 40} = image] = content_images(link)
      assert html =~ ~s(<img src="/images/#{image.id}" alt="Hive" width="40" height="40">)
      assert html =~ "<h2>Bees</h2><p>Paragraph 1"
      refute html =~ ~r/missing|tiny|javascript|onclick|Home/
      assert html =~ "trap"

      # Content images never show on the card.
      assert_receive {:link_updated, %Link{images: []}}
    end

    test "prefers the page's Markdown", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/bees")
      markdown = "# Bees\n\n" <> String.duplicate("Bees *pollinate* crops. ", 12)

      Req.Test.stub(SafeFetch, fn
        %{request_path: "/posts/bees.md"} = conn ->
          conn |> Plug.Conn.put_resp_content_type("text/markdown", nil) |> Plug.Conn.send_resp(200, markdown)

        conn ->
          conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, article_html())
      end)

      assert :ok = perform(link)

      assert %{content_source: :markdown, content_html: "<h2>Bees</h2><p>Bees <em>pollinate</em>" <> _} =
               reader_link(link)
    end

    test "a page with too little to read records no content", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/bees")
      stub_site(page_html([]), %{})

      assert :ok = perform(link)
      assert %{content_html: nil, content_source: nil, content_extracted_at: %DateTime{}} = reader_link(link)
    end

    test "YouTube, X and Instagram keep their embeds instead", %{scope: scope} do
      link = link_fixture(scope, "https://x.com/jack/status/20")

      Req.Test.stub(SafeFetch, fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, article_html())
      end)

      perform(link)
      assert %{content_html: nil, content_extracted_at: nil} = reader_link(link)
    end

    test "a crash while extracting it never fails the capture", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/bees")

      Req.Test.stub(SafeFetch, fn
        %{request_path: "/posts/bees.md"} -> raise "boom"
        conn -> conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, article_html())
      end)

      log = capture_log(fn -> assert :ok = perform(link) end)

      assert log =~ "reader content of link #{link.id} crashed"
      assert %Link{status: :ready, title: "Bees", capture_error: nil} = Repo.get!(Link, link.id)
      assert %{content_extracted_at: nil} = reader_link(link)
    end
  end

  describe "enrichment" do
    test "a saved capture enqueues it and marks the link pending", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/bees")
      stub_site(page_html([]), %{})

      assert :ok = perform(link)

      assert_enqueued(worker: EnrichLink, args: %{"link_id" => link.id})
      assert %Link{enrichment_status: :pending} = Repo.get!(Link, link.id)
    end

    test "a blocked or failed capture does not", %{scope: scope} do
      blocked = link_fixture(scope, "https://internal.test/admin")
      gone = link_fixture(scope, "https://example.com/posts/gone")
      Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 404, ""))

      assert :ok = perform(blocked)
      assert :ok = perform(gone)

      refute_enqueued(worker: EnrichLink)
      assert %Link{enrichment_status: nil} = Repo.get!(Link, blocked.id)
    end

    test "a re-capture of an enriched link does not enqueue it again", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/bees")
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [enriched_at: DateTime.utc_now(:second)])
      stub_site(page_html([]), %{})

      assert :ok = perform(link)
      refute_enqueued(worker: EnrichLink)
    end
  end

  describe "permanent errors" do
    test "a missing page ends ready with the error and no retry", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/gone")
      Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 404, ""))

      assert :ok = perform(link)
      assert %Link{status: :ready, capture_error: "not_found"} = Repo.get!(Link, link.id)
      assert_receive {:link_updated, %Link{status: :ready, capture_error: "not_found"}}
    end

    test "a 4xx status is recorded as http_<status>", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/private")
      Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 403, ""))

      assert :ok = perform(link)
      assert %Link{status: :ready, capture_error: "http_403"} = Repo.get!(Link, link.id)
    end

    test "a blocked address is not retried", %{scope: scope} do
      link = link_fixture(scope, "https://internal.test/admin")

      assert :ok = perform(link)
      assert %Link{status: :ready, capture_error: "blocked_address"} = Repo.get!(Link, link.id)
    end
  end

  describe "transient errors" do
    test "retries while attempts remain", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/flaky")
      Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 503, ""))

      assert {:error, {:http, 503}} = perform(link, attempt: 1)
      assert %Link{status: :pending, capture_error: nil} = Repo.get!(Link, link.id)
      assert_receive {:link_updated, %Link{status: :pending}}
    end

    test "fails on the final attempt", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/flaky")
      Req.Test.stub(SafeFetch, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:transport, :econnrefused}} = perform(link, attempt: 5)
      assert %Link{status: :failed, capture_error: "transport_econnrefused"} = Repo.get!(Link, link.id)
      assert_receive {:link_updated, %Link{status: :failed}}
    end
  end

  describe "crashes" do
    setup do
      Req.Test.stub(SafeFetch, fn _conn -> raise "<p>secret page content</p>" end)
      :ok
    end

    test "retry while attempts remain and log no page content", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/bees")

      log = capture_log(fn -> assert {:error, :crashed} = perform(link, attempt: 1) end)

      assert %Link{status: :pending, capture_error: nil} = Repo.get!(Link, link.id)
      assert_receive {:link_updated, %Link{status: :pending}}
      assert log =~ "capture of link #{link.id} crashed with RuntimeError"
      refute log =~ "secret page content"
    end

    test "fail on the final attempt", %{scope: scope} do
      link = link_fixture(scope, "https://example.com/posts/bees")

      capture_log(fn -> assert {:error, :crashed} = perform(link, attempt: 5) end)

      assert %Link{status: :failed, capture_error: "crashed"} = Repo.get!(Link, link.id)
      assert_receive {:link_updated, %Link{status: :failed, capture_error: "crashed"}}
    end
  end

  describe "dedupe" do
    setup do
      Req.Test.stub(SafeFetch, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, page_html([], "https://x.test/a"))
      end)

      :ok
    end

    test "the canonical url is the immutable key and the resolved url also matches", %{scope: scope} do
      assert {:ok, link, :created} = Library.save_link(scope, "http://x.test/a")
      assert link.canonical_url == "http://x.test/a"

      assert :ok = perform(link)

      assert %Link{canonical_url: "http://x.test/a", resolved_url: "https://x.test/a"} = Repo.get!(Link, link.id)
      assert {:ok, %Link{id: id}, :existing} = Library.save_link(scope, "http://x.test/a")
      assert id == link.id
      assert {:ok, %Link{id: ^id}, :existing} = Library.save_link(scope, "https://x.test/a")
      assert Library.count_links(scope) == 1
    end

    test "a resolved url of another user does not match", %{scope: scope} do
      {:ok, link, :created} = Library.save_link(scope, "http://x.test/a")
      assert :ok = perform(link)

      assert {:ok, _link, :created} = Library.save_link(user_scope_fixture(), "https://x.test/a")
    end
  end

  test "a deleted link is a no-op", %{scope: scope} do
    link = link_fixture(scope)
    {:ok, _} = Library.delete_link(scope, link)

    assert :ok = perform(link)
    assert :ok = perform_job(CaptureLink, %{"link_id" => Ecto.UUID.generate()})
  end
end
