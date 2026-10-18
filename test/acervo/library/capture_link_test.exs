defmodule Acervo.Library.CaptureLinkTest do
  use Acervo.DataCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures

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
      assert link.canonical_url == "https://example.com/posts/bees-canonical"

      assert [%LinkImage{position: 0} = first, %LinkImage{position: 1}] = images_of(link)
      assert first.kind == :preview
      assert first.content_type == "image/webp"
      assert <<"RIFF", _::binary-size(4), "WEBP", _::binary>> = first.bytes

      assert_receive {:link_updated, %Link{status: :ready, images: [_, _]}}
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

    test "keeps the canonical url when another link already has it", %{scope: scope} do
      _taken = link_fixture(scope, "https://example.com/taken")
      link = link_fixture(scope, "https://example.com/posts/bees")
      stub_site(page_html([], "https://example.com/taken"), %{})

      assert :ok = perform(link)
      assert %Link{status: :ready, canonical_url: "https://example.com/posts/bees"} = Repo.get!(Link, link.id)
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

  test "a deleted link is a no-op", %{scope: scope} do
    link = link_fixture(scope)
    {:ok, _} = Library.delete_link(scope, link)

    assert :ok = perform(link)
    assert :ok = perform_job(CaptureLink, %{"link_id" => Ecto.UUID.generate()})
  end
end
