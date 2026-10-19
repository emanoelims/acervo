defmodule Acervo.Library.CaptureLinkSnapshotTest do
  # The screenshot service's config is global.
  use Acervo.DataCase, async: false
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.AI.EnrichLink
  alias Acervo.Library.CaptureLink
  alias Acervo.Library.CaptureSnapshot
  alias Acervo.Library.Link
  alias Acervo.Library.SafeFetch
  alias Acervo.Search.EmbedLink

  setup :enable_snapshots

  setup do
    %{scope: user_scope_fixture()}
  end

  defp page_html(image_paths) do
    images = Enum.map_join(image_paths, "\n", &~s(<meta property="og:image" content="#{&1}">))

    """
    <!doctype html>
    <html><head><meta property="og:title" content="Bees">#{images}</head>
    <body><article><p>Bees pollinate crops.</p></article></body></html>
    """
  end

  defp stub_page(html) do
    Req.Test.stub(SafeFetch, fn
      %{request_path: "/img/a.png"} = conn ->
        conn |> Plug.Conn.put_resp_content_type("image/png", nil) |> Plug.Conn.send_resp(200, image_fixture("wide.png"))

      conn ->
        conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, html)
    end)
  end

  defp perform(link, opts \\ []), do: perform_job(CaptureLink, %{"link_id" => link.id}, opts)

  test "a page without images gets a snapshot, which enriches the link in the capture's place", %{scope: scope} do
    link = link_fixture(scope, "https://example.com/posts/bees")
    stub_page(page_html([]))

    assert :ok = perform(link, priority: 2)

    assert_enqueued(worker: CaptureSnapshot, args: %{"link_id" => link.id, "replace" => false}, priority: 2)
    refute_enqueued(worker: EnrichLink)
    refute_enqueued(worker: EmbedLink)
    assert %Link{enrichment_status: nil} = Repo.get!(Link, link.id)
  end

  test "a page with a preview image is enriched as before", %{scope: scope} do
    link = link_fixture(scope, "https://example.com/posts/bees")
    stub_page(page_html(["/img/a.png"]))

    assert :ok = perform(link)

    assert_enqueued(worker: EnrichLink, args: %{"link_id" => link.id})
    refute_enqueued(worker: CaptureSnapshot)
  end

  test "a re-capture of an enriched link without images embeds it and gets a snapshot", %{scope: scope} do
    link = link_fixture(scope, "https://example.com/posts/bees")
    Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [enriched_at: DateTime.utc_now(:second)])
    stub_page(page_html([]))

    assert :ok = perform(link)

    assert_enqueued(worker: CaptureSnapshot, args: %{"link_id" => link.id})
    assert_enqueued(worker: EmbedLink, args: %{"link_id" => link.id})
    refute_enqueued(worker: EnrichLink)
  end

  test "a permanent error a browser may get past gets a snapshot", %{scope: scope} do
    link = link_fixture(scope, "https://example.com/posts/private")
    Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 403, ""))

    assert :ok = perform(link, priority: 2)

    assert %Link{status: :ready, capture_error: "http_403"} = Repo.get!(Link, link.id)
    assert_enqueued(worker: CaptureSnapshot, args: %{"link_id" => link.id, "replace" => false}, priority: 2)
    assert_enqueued(worker: EmbedLink, args: %{"link_id" => link.id})
  end

  test "a missing page or a refused address gets none", %{scope: scope} do
    gone = link_fixture(scope, "https://example.com/posts/gone")
    blocked = link_fixture(scope, "https://internal.test/admin")
    Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 404, ""))

    assert :ok = perform(gone)
    assert :ok = perform(blocked)

    refute_enqueued(worker: CaptureSnapshot)
  end

  test "a transient error gets none", %{scope: scope} do
    link = link_fixture(scope, "https://example.com/posts/flaky")
    Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 503, ""))

    assert {:error, _} = perform(link, attempt: 1)
    refute_enqueued(worker: CaptureSnapshot)
  end

  test "YouTube, X and Instagram keep their own images", %{scope: scope} do
    link = link_fixture(scope, "https://www.instagram.com/p/xyz/")
    Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 403, ""))

    assert :ok = perform(link)
    refute_enqueued(worker: CaptureSnapshot)
  end
end
