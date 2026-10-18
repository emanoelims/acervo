defmodule Acervo.Library.ExtractContentTest do
  use Acervo.DataCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.AI.EnrichLink
  alias Acervo.Collections
  alias Acervo.Library
  alias Acervo.Library.ExtractContent
  alias Acervo.Library.Images
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage
  alias Acervo.Library.SafeFetch
  alias Acervo.Release
  alias Acervo.Search.EmbedLink

  setup do
    scope = user_scope_fixture()
    Library.subscribe(scope)
    %{scope: scope}
  end

  defp page(image_path) do
    paragraphs = Enum.map_join(1..3, &"<p>Paragraph #{&1}: bees pollinate crops and make honey for the hive.</p>")

    """
    <html><head><meta property="og:title" content="A new title"></head>
    <body><article><h1>Bees</h1>#{paragraphs}<p><img src="#{image_path}" alt="Hive"></p></article></body></html>
    """
  end

  defp stub_page(image_path, image) do
    Req.Test.stub(SafeFetch, fn
      %{request_path: ^image_path} = conn ->
        conn |> Plug.Conn.put_resp_content_type("image/png", nil) |> Plug.Conn.send_resp(200, image)

      %{request_path: "/posts/bees"} = conn ->
        conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, page(image_path))

      conn ->
        Plug.Conn.send_resp(conn, 404, "")
    end)
  end

  defp png(size), do: size |> Image.new!(size, color: :blue) |> Image.write!(:memory, suffix: ".png")

  # A link captured before reader content existed, with a note, a collection
  # and a preview image of its own.
  defp captured_link(scope) do
    link = link_fixture(scope, "https://example.com/posts/bees")

    link =
      link
      |> Link.capture_changeset(%{status: :ready, title: "Old title", description: "Old description"})
      |> Repo.update!()

    {:ok, link} = Library.update_note(scope, link, %{note: "my note"})
    collection = collection_fixture(scope, %{name: "Bees"})
    :ok = Collections.add_link(scope, collection, link)
    {:ok, _} = Acervo.Storage.put(scope, link, Map.put(image(png(30)), :kind, :preview))
    link
  end

  defp image(bytes) do
    {:ok, image} = Images.normalize(bytes)
    image
  end

  defp images(link, kind), do: Repo.all(from i in LinkImage, where: i.link_id == ^link.id and i.kind == ^kind)

  defp content(link), do: Repo.one!(from l in Link, where: l.id == ^link.id, select: l.content_html)

  test "fills only the reader content and its images", %{scope: scope} do
    link = captured_link(scope)
    [preview] = images(link, :preview)
    stub_page("/img/a.png", png(40))

    assert :ok = perform_job(ExtractContent, %{"link_id" => link.id})

    after_run = scope |> Library.get_link!(link.id) |> Repo.preload(:collections, force: true)
    assert %Link{title: "Old title", description: "Old description", note: "my note", status: :ready} = after_run
    assert [%{name: "Bees"}] = after_run.collections
    assert [%{id: preview_id}] = after_run.images
    assert preview_id == preview.id
    assert after_run.content_source == :html
    assert after_run.content_extracted_at

    assert [image] = images(link, :content)
    assert content(link) =~ ~s(<img src="/images/#{image.id}" alt="Hive" width="40" height="40">)
    assert_receive {:link_updated, %Link{id: id}} when id == link.id
  end

  test "enqueues enrichment for a never-enriched link that gained content", %{scope: scope} do
    link = captured_link(scope)
    stub_page("/img/a.png", png(40))

    assert :ok = perform_job(ExtractContent, %{"link_id" => link.id})

    assert_enqueued(worker: EnrichLink, args: %{"link_id" => link.id})
    assert %Link{enrichment_status: :pending} = Repo.get!(Link, link.id)
  end

  test "does not enqueue enrichment for an enriched or already pending link", %{scope: scope} do
    enriched = captured_link(scope)
    other = user_scope_fixture()
    pending = captured_link(other)
    Repo.update_all(from(l in Link, where: l.id == ^enriched.id), set: [enriched_at: DateTime.utc_now(:second)])
    Repo.update_all(from(l in Link, where: l.id == ^pending.id), set: [enrichment_status: :pending])

    for link <- [enriched, pending] do
      stub_page("/img/a.png", png(40))
      assert :ok = perform_job(ExtractContent, %{"link_id" => link.id})
    end

    refute_enqueued(worker: EnrichLink)
  end

  test "does not enqueue enrichment for a page with no content", %{scope: scope} do
    link = captured_link(scope)
    Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 404, ""))

    assert :ok = perform_job(ExtractContent, %{"link_id" => link.id})
    refute_enqueued(worker: EnrichLink)
  end

  describe "search embedding" do
    # The fixture's note and collection enqueued an embedding already.
    defp clear_jobs(link) do
      Repo.delete_all(Oban.Job)
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [embedding_status: nil])
    end

    test "new content of an enriched link enqueues it", %{scope: scope} do
      link = captured_link(scope)
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [enriched_at: DateTime.utc_now(:second)])
      clear_jobs(link)
      stub_page("/img/a.png", png(40))

      assert :ok = perform_job(ExtractContent, %{"link_id" => link.id})

      assert_enqueued(worker: EmbedLink, args: %{"link_id" => link.id})
      refute_enqueued(worker: EnrichLink)
      assert %Link{embedding_status: :pending} = Repo.get!(Link, link.id)
    end

    test "new content of a never-enriched link leaves it to enrichment", %{scope: scope} do
      link = captured_link(scope)
      clear_jobs(link)
      stub_page("/img/a.png", png(40))

      assert :ok = perform_job(ExtractContent, %{"link_id" => link.id})

      assert_enqueued(worker: EnrichLink, args: %{"link_id" => link.id})
      refute_enqueued(worker: EmbedLink)
    end

    test "embeds it even when the loaded link looks mid-enrichment", %{scope: scope} do
      link = captured_link(scope)
      clear_jobs(link)
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [enrichment_status: :pending])
      stub_page("/img/a.png", png(40))

      assert :ok = perform_job(ExtractContent, %{"link_id" => link.id})
      assert_enqueued(worker: EmbedLink, args: %{"link_id" => link.id})
    end

    test "a transient failure does not", %{scope: scope} do
      link = captured_link(scope)
      clear_jobs(link)
      Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 503, ""))

      assert {:error, _} = perform_job(ExtractContent, %{"link_id" => link.id})
      refute_enqueued(worker: EmbedLink)
    end
  end

  test "running it again replaces the content images", %{scope: scope} do
    link = captured_link(scope)
    stub_page("/img/a.png", png(40))
    assert :ok = perform_job(ExtractContent, %{"link_id" => link.id})
    [first] = images(link, :content)

    stub_page("/img/b.png", png(50))
    assert :ok = perform_job(ExtractContent, %{"link_id" => link.id})

    assert [second] = images(link, :content)
    assert second.id != first.id
    assert second.width == 50
    assert content(link) =~ "/images/#{second.id}"
    refute content(link) =~ first.id
    assert [_preview] = images(link, :preview)
  end

  test "a page gone for good records no content; other errors retry", %{scope: scope} do
    link = captured_link(scope)

    Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 503, ""))
    assert {:error, {:http, 503}} = perform_job(ExtractContent, %{"link_id" => link.id})
    assert %Link{content_extracted_at: nil} = Repo.get!(Link, link.id)

    Req.Test.stub(SafeFetch, &Plug.Conn.send_resp(&1, 404, ""))
    assert :ok = perform_job(ExtractContent, %{"link_id" => link.id})
    assert %Link{content_extracted_at: %DateTime{}, content_html: nil} = Repo.reload!(link)
  end

  test "skips YouTube, X and Instagram and missing links", %{scope: scope} do
    video = link_fixture(scope, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")

    assert :ok = perform_job(ExtractContent, %{"link_id" => video.id})
    assert :ok = perform_job(ExtractContent, %{"link_id" => Ecto.UUID.generate()})
    assert %Link{content_extracted_at: nil} = Repo.get!(Link, video.id)
  end

  test "the backfill selects ready generic links never extracted", %{scope: scope} do
    missing = captured_link(scope)
    pending = link_fixture(scope, "https://example.com/pending")
    video = scope |> link_fixture("https://www.youtube.com/watch?v=dQw4w9WgXcQ") |> ready()
    failed = scope |> link_fixture("https://example.com/blocked") |> ready(%{capture_error: "blocked"})

    done =
      scope
      |> link_fixture("https://example.com/done")
      |> ready()
      |> Link.content_changeset(%{content_extracted_at: DateTime.utc_now(:second)})
      |> Repo.update!()

    ids = Release.missing_reader_content(Repo)

    assert missing.id in ids
    for link <- [pending, video, failed, done], do: refute(link.id in ids)
  end

  test "the enrichment backfill selects ready links never enriched or failed", %{scope: scope} do
    missing = scope |> link_fixture() |> ready()
    failed = scope |> link_fixture() |> ready() |> status(:failed)
    pending = scope |> link_fixture() |> ready() |> status(:pending)
    done = scope |> link_fixture() |> ready() |> status(:ready)
    capturing = link_fixture(scope)

    ids = Release.missing_enrichment(Repo)

    assert missing.id in ids
    assert failed.id in ids
    for link <- [pending, done, capturing], do: refute(link.id in ids)
  end

  defp status(link, status), do: link |> Ecto.Changeset.change(enrichment_status: status) |> Repo.update!()

  defp ready(link, attrs \\ %{}), do: link |> Link.capture_changeset(Map.put(attrs, :status, :ready)) |> Repo.update!()
end
