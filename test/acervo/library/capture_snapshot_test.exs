defmodule Acervo.Library.CaptureSnapshotTest do
  # The screenshot service's config is global.
  use Acervo.DataCase, async: false
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures, only: [collection_link_image_fixture: 2]
  import Acervo.LibraryFixtures
  import ExUnit.CaptureLog

  alias Acervo.AI.EnrichLink
  alias Acervo.Library
  alias Acervo.Library.CaptureSnapshot
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage
  alias Acervo.Library.Screenshots
  alias Acervo.Search.EmbedLink

  setup :enable_snapshots

  setup do
    scope = user_scope_fixture()
    Library.subscribe(scope)
    %{scope: scope}
  end

  defp ready_link(scope, attrs \\ []) do
    link = link_fixture(scope)
    Repo.update_all(from(l in Link, where: l.id == ^link.id), set: Keyword.merge([status: :ready], attrs))
    Repo.get!(Link, link.id)
  end

  defp enriched, do: [enriched_at: DateTime.utc_now(:second), enrichment_status: :ready]

  defp stub_shot(test \\ nil) do
    Req.Test.stub(Screenshots, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      if test, do: send(test, {:shot, JSON.decode!(body)["url"]})
      conn |> Plug.Conn.put_resp_content_type("image/jpeg", nil) |> Plug.Conn.send_resp(200, image_fixture("photo.jpg"))
    end)
  end

  defp stub_status(status) do
    Req.Test.stub(Screenshots, &Plug.Conn.send_resp(&1, status, ~s({"error": "nope"})))
  end

  defp images_of(link) do
    Repo.all(from i in LinkImage, where: i.link_id == ^link.id, order_by: [i.position, i.kind])
  end

  defp perform(link, replace, opts \\ []) do
    perform_job(CaptureSnapshot, %{"link_id" => link.id, "replace" => replace}, opts)
  end

  describe "storing" do
    test "stores the page's first screen as a WebP snapshot", %{scope: scope} do
      link = ready_link(scope)
      stub_shot(self())

      assert :ok = perform(link, false)

      assert_received {:shot, url}
      assert url == link.canonical_url
      assert [%LinkImage{kind: :snapshot, position: 0, content_type: "image/webp"} = image] = images_of(link)
      assert <<"RIFF", _::binary-size(4), "WEBP", _::binary>> = image.bytes
      assert_receive {:link_updated, %Link{images: [%{kind: :snapshot}]}}
    end

    test "shoots the page where the link resolved to", %{scope: scope} do
      link = ready_link(scope, resolved_url: "https://example.com/bees")
      stub_shot(self())

      assert :ok = perform(link, false)
      assert_received {:shot, "https://example.com/bees"}
    end

    test "replacing drops earlier snapshots and moves the other images down", %{scope: scope} do
      link = ready_link(scope)
      collection_link_image_fixture(link, %{kind: :snapshot, position: 0, sha256: String.duplicate("a", 64)})
      collection_link_image_fixture(link, %{kind: :screenshot, position: 1, sha256: String.duplicate("b", 64)})
      collection_link_image_fixture(link, %{kind: :preview, position: 2, sha256: String.duplicate("c", 64)})
      content = collection_link_image_fixture(link, %{kind: :content, position: 0, sha256: String.duplicate("d", 64)})
      stub_shot()

      assert :ok = perform(link, true)

      assert [
               %LinkImage{kind: :content, position: 0},
               %LinkImage{kind: :snapshot, position: 0, sha256: sha},
               %LinkImage{kind: :screenshot, position: 2},
               %LinkImage{kind: :preview, position: 3}
             ] = images_of(link)

      assert sha != String.duplicate("a", 64)
      assert Repo.get!(LinkImage, content.id).position == 0
    end

    test "without replace, a link that has a card image is left alone", %{scope: scope} do
      link = ready_link(scope, enriched())
      collection_link_image_fixture(link, %{kind: :preview})
      Req.Test.stub(Screenshots, fn _conn -> flunk("no screenshot expected") end)

      assert :ok = perform(link, false)

      assert [%LinkImage{kind: :preview}] = images_of(link)
      refute_enqueued(worker: EnrichLink)
    end

    test "a deleted link is a no-op", %{scope: scope} do
      link = ready_link(scope)
      {:ok, _} = Library.delete_link(scope, link)

      assert :ok = perform(link, true)
      assert :ok = perform_job(CaptureSnapshot, %{"link_id" => Ecto.UUID.generate(), "replace" => false})
    end
  end

  describe "errors" do
    test "a busy service snoozes the job", %{scope: scope} do
      link = ready_link(scope)
      stub_status(503)

      assert {:snooze, 30} = perform(link, true)
      refute_enqueued(worker: EnrichLink)
      refute_receive {:snapshot_failed, _}
    end

    test "after many snoozes, busy counts as a transient error", %{scope: scope} do
      link = ready_link(scope)
      stub_status(503)

      capture_log(fn -> assert {:error, :busy} = perform(link, true, meta: %{"snoozed" => 10}) end)
    end

    test "transient errors retry while attempts remain", %{scope: scope} do
      link = ready_link(scope)
      stub_status(500)

      log = capture_log(fn -> assert {:error, {:http, 500}} = perform(link, true, attempt: 1) end)

      assert log =~ "snapshot of link #{link.id} failed"
      refute_enqueued(worker: EnrichLink)
      refute_receive {:snapshot_failed, _}
    end

    test "permanent errors cancel the job", %{scope: scope} do
      link = ready_link(scope, enriched())

      for {status, reason} <- [{422, :rejected}, {401, :unauthorized}] do
        stub_status(status)
        capture_log(fn -> assert {:cancel, ^reason} = perform(link, false) end)
      end

      assert images_of(link) == []
    end

    test "an answer that is not an image cancels the job", %{scope: scope} do
      link = ready_link(scope, enriched())

      Req.Test.stub(Screenshots, fn conn ->
        conn |> Plug.Conn.put_resp_content_type("image/jpeg", nil) |> Plug.Conn.send_resp(200, "not a jpeg")
      end)

      capture_log(fn -> assert {:cancel, :not_an_image} = perform(link, false) end)
    end

    test "a requested snapshot that fails for good says so", %{scope: scope} do
      link = ready_link(scope, enriched())
      id = link.id

      stub_status(422)
      capture_log(fn -> assert {:cancel, :rejected} = perform(link, true) end)
      assert_receive {:snapshot_failed, %Link{id: ^id}}

      stub_status(500)
      capture_log(fn -> assert {:error, {:http, 500}} = perform(link, true, attempt: 3) end)
      assert_receive {:snapshot_failed, %Link{id: ^id}}
    end

    test "an automatic snapshot fails quietly", %{scope: scope} do
      link = ready_link(scope, enriched())
      stub_status(422)

      capture_log(fn -> assert {:cancel, :rejected} = perform(link, false) end)
      refute_receive {:snapshot_failed, _}
    end
  end

  describe "enrichment" do
    test "a link never enriched is enqueued at the job's priority once stored", %{scope: scope} do
      link = ready_link(scope)
      stub_shot()

      assert :ok = perform(link, false, priority: 2)

      assert_enqueued(worker: EnrichLink, args: %{"link_id" => link.id}, priority: 2)
      assert_receive {:link_updated, %Link{enrichment_status: :pending}}
    end

    test "a link never enriched is enqueued when the snapshot fails for good or is skipped", %{scope: scope} do
      failed = ready_link(scope)
      stub_status(500)
      capture_log(fn -> assert {:error, _} = perform(failed, false, attempt: 3, priority: 2) end)
      assert_enqueued(worker: EnrichLink, args: %{"link_id" => failed.id}, priority: 2)

      rejected = ready_link(scope)
      stub_status(422)
      capture_log(fn -> assert {:cancel, _} = perform(rejected, false) end)
      assert_enqueued(worker: EnrichLink, args: %{"link_id" => rejected.id})

      skipped = ready_link(scope)
      collection_link_image_fixture(skipped, %{kind: :preview})
      assert :ok = perform(skipped, false)
      assert_enqueued(worker: EnrichLink, args: %{"link_id" => skipped.id})
    end

    test "a requested snapshot enriches an enriched link again", %{scope: scope} do
      link = ready_link(scope, enriched())
      stub_shot()

      assert :ok = perform(link, true)

      assert_enqueued(worker: EnrichLink, args: %{"link_id" => link.id})
      assert %Link{enrichment_status: :pending} = Repo.get!(Link, link.id)
    end

    test "an enriched link is not enriched again by an automatic snapshot or a failure", %{scope: scope} do
      link = ready_link(scope, enriched())
      stub_shot()
      assert :ok = perform(link, false)

      stub_status(422)
      capture_log(fn -> assert {:cancel, _} = perform(link, true) end)

      refute_enqueued(worker: EnrichLink)
      refute_enqueued(worker: EmbedLink)
    end
  end

  describe "enqueue/2" do
    test "a requested snapshot does not collapse into an automatic one", %{scope: scope} do
      link = ready_link(scope)

      assert {:ok, %{conflict?: false}} = CaptureSnapshot.enqueue(link, priority: 2)
      assert {:ok, %{conflict?: true}} = CaptureSnapshot.enqueue(link, priority: 2)
      assert {:ok, %{conflict?: false}} = CaptureSnapshot.enqueue(link, replace: true)

      assert_enqueued(worker: CaptureSnapshot, args: %{"link_id" => link.id, "replace" => false}, priority: 2)
      assert_enqueued(worker: CaptureSnapshot, args: %{"link_id" => link.id, "replace" => true}, priority: 0)
    end
  end
end
