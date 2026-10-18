defmodule Acervo.LibraryTest do
  use Acervo.DataCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures, only: [collection_fixture: 1]
  import Acervo.LibraryFixtures

  alias Acervo.Collections
  alias Acervo.Library
  alias Acervo.Library.CaptureLink
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage

  setup do
    scope = user_scope_fixture()
    Library.subscribe(scope)
    %{scope: scope}
  end

  describe "save_link/2" do
    test "creates a link with its source, enqueues a capture and broadcasts", %{scope: scope} do
      assert {:ok, %Link{} = link, :created} = Library.save_link(scope, "https://x.com/jack/status/20?s=1")

      assert link.user_id == scope.user.id
      assert link.canonical_url == "https://x.com/jack/status/20"
      assert link.source == :x
      assert link.status == :pending
      assert_enqueued(worker: CaptureLink, args: %{"link_id" => link.id})
      assert_receive {:link_created, %Link{id: id}}
      assert id == link.id
    end

    test "returns the existing link for the same canonical url", %{scope: scope} do
      assert {:ok, link, :created} = Library.save_link(scope, "https://x.com/a?s=1")
      assert {:ok, existing, :existing} = Library.save_link(scope, "https://twitter.com/a")

      assert existing.id == link.id
      assert [_] = all_enqueued(worker: CaptureLink)
      assert Library.count_links(scope) == 1
      assert_receive {:link_created, _}
      refute_receive {:link_created, _}
    end

    test "rejects an invalid url", %{scope: scope} do
      assert {:error, :invalid_url} = Library.save_link(scope, "not a url")
      assert {:error, :invalid_url} = Library.save_link(scope, "ftp://example.com/file")
      refute_enqueued(worker: CaptureLink)
    end

    test "the same url is a separate link for another user", %{scope: scope} do
      other = user_scope_fixture()
      assert {:ok, a, :created} = Library.save_link(scope, "https://example.com/shared")
      assert {:ok, b, :created} = Library.save_link(other, "https://example.com/shared")
      assert a.id != b.id
    end

    test "returns the winner when a concurrent save inserts the same url first", %{scope: scope} do
      assert {:ok, winner, :created} = Library.save_link(scope, "https://example.com/race")
      assert_receive {:link_created, _}

      # The insert path after a lookup that found nothing, losing to the winner.
      assert {:ok, %Link{} = link, :existing} =
               Library.insert_link(scope, "https://example.com/race?again", "https://example.com/race")

      assert link.id == winner.id
      assert [_] = all_enqueued(worker: CaptureLink)
      refute_receive {:link_created, _}
    end
  end

  describe "isolation" do
    test "get_link! raises for another user's link", %{scope: scope} do
      link = link_fixture(scope)
      other = user_scope_fixture()

      assert Library.get_link!(scope, link.id).id == link.id
      assert_raise Ecto.NoResultsError, fn -> Library.get_link!(other, link.id) end
    end

    test "list and count functions are scoped", %{scope: scope} do
      link_fixture(scope)
      other = user_scope_fixture()
      other_link = link_fixture(other)

      assert [%Link{}] = Library.list_links(scope)
      assert [%Link{id: id}] = Library.list_links(other)
      assert id == other_link.id
      assert Library.count_links(scope) == 1
      assert Library.count_inbox(scope) == 1
    end

    test "mutations refuse another user's link", %{scope: scope} do
      link = link_fixture(scope)
      other = user_scope_fixture()

      assert {:error, :not_found} = Library.update_note(other, link, %{note: "hi"})
      assert {:error, :not_found} = Library.mark_triaged(other, link)
      assert {:error, :not_found} = Library.delete_link(other, link)
      assert {:error, :not_found} = Library.attach_screenshot(other, link, image_fixture("photo.jpg"))
      assert Repo.get!(Link, link.id).note == nil
    end
  end

  describe "list_links/2" do
    test "lists newest first and honors the limit", %{scope: scope} do
      first = link_fixture(scope)
      second = link_fixture(scope)
      Repo.update_all(from(l in Link, where: l.id == ^first.id), set: [inserted_at: ~U[2020-01-01 00:00:00Z]])

      assert [%{id: a}, %{id: b}] = Library.list_links(scope, filter: :all)
      assert [a, b] == [second.id, first.id]
      assert [_] = Library.list_links(scope, limit: 1)
    end

    test "filters the inbox to untriaged links", %{scope: scope} do
      triaged = link_fixture(scope)
      inbox = link_fixture(scope)
      {:ok, _} = Library.mark_triaged(scope, triaged)

      assert [%{id: id}] = Library.list_links(scope, filter: :inbox)
      assert id == inbox.id
      assert Library.count_inbox(scope) == 1
      assert Library.count_links(scope) == 2
    end

    test "filters by collection and preloads collections", %{scope: scope} do
      member = link_fixture(scope)
      _outside = link_fixture(scope)
      collection = collection_fixture(scope)
      :ok = Collections.add_link(scope, collection, member)

      assert [%{id: id, collections: [%{id: cid}]}] = Library.list_links(scope, filter: {:collection, collection.id})
      assert id == member.id
      assert cid == collection.id
    end

    test "preloads only the first image", %{scope: scope} do
      link = link_fixture(scope)
      insert_image(link, 0, "a")
      insert_image(link, 1, "b")

      assert [%{images: [%LinkImage{position: 0}]}] = Library.list_links(scope, [])
      assert [_, _] = Library.get_link!(scope, link.id).images
    end
  end

  describe "update_note/3 and mark_triaged/2" do
    test "update_note saves the note and broadcasts", %{scope: scope} do
      link = link_fixture(scope)

      assert {:ok, %Link{note: "worth reading"}} = Library.update_note(scope, link, %{note: "worth reading"})
      assert_receive {:link_updated, %Link{note: "worth reading"}}
      assert Repo.get!(Link, link.id).note == "worth reading"
    end

    test "update_note returns an invalid changeset", %{scope: scope} do
      link = link_fixture(scope)
      assert {:error, %Ecto.Changeset{}} = Library.update_note(scope, link, %{note: String.duplicate("a", 4001)})
    end

    test "mark_triaged sets triaged_at and broadcasts", %{scope: scope} do
      link = link_fixture(scope)

      assert {:ok, %Link{triaged_at: %DateTime{}}} = Library.mark_triaged(scope, link)
      assert_receive {:link_updated, %Link{triaged_at: %DateTime{}}}
    end
  end

  describe "delete_link/2" do
    test "deletes and broadcasts", %{scope: scope} do
      link = link_fixture(scope)

      assert {:ok, _} = Library.delete_link(scope, link)
      assert_receive {:link_deleted, %Link{id: id, images: [], collections: []}}
      assert id == link.id
      refute Repo.get(Link, link.id)
    end
  end

  describe "attach_screenshot/3" do
    test "stores the screenshot first, moving previews down", %{scope: scope} do
      link = link_fixture(scope)
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [status: :failed, capture_error: "timeout"])
      insert_image(link, 0, "a")

      assert {:ok, %Link{status: :ready, capture_error: nil} = updated} =
               Library.attach_screenshot(scope, link, image_fixture("photo.jpg"))

      assert [%{kind: :screenshot, position: 0, content_type: "image/webp"}, %{kind: :preview, position: 1}] =
               updated.images

      assert_receive {:link_updated, %Link{status: :ready}}
    end

    @tag :capture_log
    test "rejects bytes that are not an image", %{scope: scope} do
      link = link_fixture(scope)
      assert {:error, :not_an_image} = Library.attach_screenshot(scope, link, image_fixture("not_image.txt"))
      assert Repo.aggregate(from(i in LinkImage, where: i.link_id == ^link.id), :count) == 0
    end
  end

  defp insert_image(link, position, char) do
    %LinkImage{link_id: link.id}
    |> LinkImage.changeset(%{
      position: position,
      kind: :preview,
      content_type: "image/webp",
      bytes: <<1, 2, 3>>,
      width: 1,
      height: 1,
      sha256: String.duplicate(char, 64)
    })
    |> Repo.insert!()
  end
end
