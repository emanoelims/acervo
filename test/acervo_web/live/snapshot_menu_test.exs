defmodule AcervoWeb.SnapshotMenuTest do
  # The screenshot service's config is global.
  use AcervoWeb.ConnCase, async: false
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.CollectionsFixtures, only: [collection_link_image_fixture: 2]
  import Acervo.LibraryFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Acervo.Library
  alias Acervo.Library.CaptureSnapshot
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage
  alias Acervo.Repo

  setup :register_and_log_in_user

  defp ready_link(scope) do
    scope |> link_fixture() |> Link.capture_changeset(%{status: :ready}) |> Repo.update!()
  end

  describe "with the screenshot service on" do
    setup :enable_snapshots

    test "the camera opens a menu to generate or upload an image", %{conn: conn, scope: scope} do
      link = ready_link(scope)
      {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")

      assert has_element?(view, "#link-image-menu summary#link-image")
      assert has_element?(view, "#link-image-menu button#link-snapshot", "Generate a new image")
      assert has_element?(view, "#link-image-menu label#link-screenshot", "Upload an image")
    end

    test "generating enqueues a snapshot and shows progress until the new image arrives", %{
      conn: conn,
      scope: scope
    } do
      link = ready_link(scope)
      collection_link_image_fixture(link, %{kind: :snapshot})
      {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")

      view |> element("#link-snapshot") |> render_click()

      assert_enqueued(worker: CaptureSnapshot, args: %{"link_id" => link.id, "replace" => true}, priority: 0)
      assert has_element?(view, "#link-snapshot[disabled][aria-busy=true]", "Generating the image…")

      # An update that brings no new snapshot keeps it busy.
      Library.broadcast_updated(scope, link.id)
      assert has_element?(view, "#link-snapshot[disabled]")

      Repo.delete_all(from i in LinkImage, where: i.link_id == ^link.id)
      collection_link_image_fixture(link, %{kind: :snapshot, sha256: String.duplicate("b", 64)})
      Library.broadcast_updated(scope, link.id)

      refute has_element?(view, "#link-snapshot[disabled]")
      assert has_element?(view, "#link-snapshot", "Generate a new image")
    end

    test "a failed snapshot stops the progress and says so", %{conn: conn, scope: scope} do
      link = ready_link(scope)
      {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")

      view |> element("#link-snapshot") |> render_click()
      assert has_element?(view, "#link-snapshot[disabled]")

      Library.broadcast_snapshot_failed(scope, link.id)

      assert render(view) =~ "Couldn&#39;t generate the image."
      refute has_element?(view, "#link-snapshot[disabled]")
    end

    test "another user's failure is not shown", %{conn: conn, scope: scope} do
      link = ready_link(scope)
      other = Acervo.AccountsFixtures.user_scope_fixture()
      other_link = ready_link(other)
      {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")

      Library.broadcast_snapshot_failed(other, other_link.id)

      refute render(view) =~ "Couldn&#39;t generate the image."
    end
  end

  test "with the service off, the camera only uploads", %{conn: conn, scope: scope} do
    link = ready_link(scope)
    {:ok, view, _html} = live(conn, ~p"/inbox/l/#{link.id}")

    assert has_element?(view, ".acts > label#link-screenshot")
    refute has_element?(view, "#link-image-menu")
    refute has_element?(view, "#link-snapshot")
    assert Library.request_snapshot(scope, link) == {:error, :disabled}
  end
end
