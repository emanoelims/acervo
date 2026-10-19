defmodule Acervo.LibraryTest do
  use Acervo.DataCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures, only: [collection_fixture: 1, collection_fixture: 2]
  import Acervo.LibraryFixtures

  alias Acervo.AI.EnrichLink
  alias Acervo.Collections
  alias Acervo.Collections.Collection
  alias Acervo.Collections.Suggestion
  alias Acervo.Library
  alias Acervo.Library.CaptureLink
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage
  alias Acervo.Search.EmbedLink

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

  describe "save_links/2" do
    test "saves each url and broadcasts the new links once", %{scope: scope} do
      existing = link_fixture(scope, "https://example.com/old")
      assert_receive {:link_created, _}

      assert %{created: [a, b], existing: [old], invalid: ["https://nodot"]} =
               Library.save_links(scope, [
                 "https://example.com/a",
                 "https://example.com/old?utm_source=x",
                 "https://nodot",
                 "https://example.com/b"
               ])

      assert {a.canonical_url, b.canonical_url} == {"https://example.com/a", "https://example.com/b"}
      assert old.id == existing.id
      assert length(all_enqueued(worker: CaptureLink)) == 3
      assert_receive {:links_created, [%Link{id: a_id}, %Link{id: b_id}]}
      assert {a_id, b_id} == {a.id, b.id}
      refute_receive {:link_created, _}
    end

    test "broadcasts nothing when nothing is new", %{scope: scope} do
      link_fixture(scope, "https://example.com/old")
      assert_receive {:link_created, _}

      assert %{created: [], existing: [_], invalid: []} = Library.save_links(scope, ["https://example.com/old"])
      refute_receive {:links_created, _}
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

  describe "home_columns/2" do
    test "the inbox first, then non-empty collections in navigation order", %{scope: scope} do
      inbox = link_fixture(scope)
      filed = link_fixture(scope)
      {:ok, _} = Library.mark_triaged(scope, filed)
      second = collection_fixture(scope, %{name: "B", position: 1})
      first = collection_fixture(scope, %{name: "A", position: 1})
      top = collection_fixture(scope, %{name: "Z", position: 0})
      _empty = collection_fixture(scope, %{name: "Empty", position: 0})
      for collection <- [second, first, top], do: :ok = Collections.add_link(scope, collection, filed)

      assert [
               %{kind: :inbox, collection: nil, links: [%{id: inbox_id}], count: 1},
               %{kind: :collection, collection: %{id: c1}, links: [%{id: l1}], count: 1},
               %{kind: :collection, collection: %{id: c2}, links: [%{id: l2}]},
               %{kind: :collection, collection: %{id: c3}, links: [%{id: l3}]}
             ] = Library.home_columns(scope)

      assert inbox_id == inbox.id
      assert [c1, c2, c3] == [top.id, first.id, second.id]
      assert [l1, l2, l3] == [filed.id, filed.id, filed.id]
    end

    test "each column holds its newest links, with its total count and first image", %{scope: scope} do
      collection = collection_fixture(scope)
      [oldest, middle, newest] = links = for _ <- 1..3, do: link_fixture(scope)
      insert_image(newest, 0, "a")
      insert_image(newest, 1, "b")

      for {link, day} <- Enum.zip(links, 1..3) do
        :ok = Collections.add_link(scope, collection, link)
        {:ok, at} = DateTime.new(Date.new!(2020, 1, day), ~T[00:00:00])
        Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [inserted_at: at])
      end

      Repo.update_all(Link, set: [triaged_at: DateTime.utc_now(:second)])

      assert [%{links: [%{id: a, images: [%LinkImage{position: 0}]}, %{id: b}], count: 3}] =
               Library.home_columns(scope, per_column: 2)

      assert [a, b] == [newest.id, middle.id]
      refute oldest.id in [a, b]
    end

    test "leaves the inbox out when nothing waits", %{scope: scope} do
      link = link_fixture(scope)
      {:ok, _} = Library.mark_triaged(scope, link)

      assert Library.home_columns(scope) == []
    end

    test "is scoped to the user", %{scope: scope} do
      other = user_scope_fixture()
      theirs = link_fixture(other)
      their_collection = collection_fixture(other)
      :ok = Collections.add_link(other, their_collection, theirs)

      assert Library.home_columns(scope) == []
      assert [%{kind: :inbox}, %{kind: :collection}] = Library.home_columns(other)
    end

    test "`only` reloads just the given columns", %{scope: scope} do
      link = link_fixture(scope)
      a = collection_fixture(scope)
      b = collection_fixture(scope)
      :ok = Collections.add_link(scope, a, link)
      :ok = Collections.add_link(scope, b, link)

      assert [%{collection: %{id: id}}] = Library.home_columns(scope, only: [b.id])
      assert id == b.id
      assert [%{kind: :inbox}] = Library.home_columns(scope, only: [:inbox])
      assert Library.home_columns(scope, only: []) == []
    end
  end

  describe "list_links_by_ids/2" do
    test "returns the scope's links in the given order, with list_links/2's preloads", %{scope: scope} do
      a = link_fixture(scope)
      b = link_fixture(scope)
      insert_image(a, 0, "a")
      insert_image(a, 1, "b")
      collection = collection_fixture(scope)
      :ok = Collections.add_link(scope, collection, a)
      theirs = link_fixture(user_scope_fixture())

      assert [%{id: first}, %{id: second, images: [%LinkImage{position: 0}], collections: [_], suggestions: []}] =
               Library.list_links_by_ids(scope, [b.id, theirs.id, Ecto.UUID.generate(), a.id])

      assert [first, second] == [b.id, a.id]
      assert Library.list_links_by_ids(scope, []) == []
    end
  end

  describe "pending suggestions" do
    setup %{scope: scope} do
      link = link_fixture(scope)
      collection = collection_fixture(scope)

      pending = insert_suggestion(scope, link, %{collection_id: collection.id}, :pending, ~U[2026-01-02 00:00:00Z])
      newest = insert_suggestion(scope, link, %{proposed_name: "Receitas"}, :pending, ~U[2026-01-03 00:00:00Z])
      insert_suggestion(scope, link, %{proposed_name: "Pães"}, :dismissed, ~U[2026-01-01 00:00:00Z])
      insert_suggestion(scope, link, %{proposed_name: "Bolos"}, :accepted, ~U[2026-01-01 00:00:00Z])

      %{link: link, collection: collection, pending: pending, newest: newest}
    end

    test "list_links/2 preloads only pending suggestions, oldest first, with their collection",
         %{scope: scope, collection: collection, pending: pending, newest: newest} do
      assert [%Link{suggestions: [first, second]}] = Library.list_links(scope)

      assert first.id == pending.id
      assert first.collection.id == collection.id
      assert second.id == newest.id
      assert second.collection == nil
    end

    test "get_link!/2 and broadcasts carry the same suggestions",
         %{scope: scope, link: link, pending: pending, newest: newest} do
      assert [%{id: a, collection: %Collection{}}, %{id: b}] = Library.get_link!(scope, link.id).suggestions
      assert [a, b] == [pending.id, newest.id]

      Library.broadcast_updated(scope, link.id)
      assert_receive {:link_updated, %Link{suggestions: [_, _]}}
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

  describe "update_ai_notes/3" do
    test "saves the edit trimmed, embeds again and broadcasts", %{scope: scope} do
      link = link_fixture(scope)

      assert {:ok, %Link{ai_notes: "Resumo\n\n- ponto"}} =
               Library.update_ai_notes(scope, link, %{"ai_notes" => "  Resumo\n\n- ponto  "})

      assert_receive {:link_updated, %Link{ai_notes: "Resumo\n\n- ponto"}}
      assert_enqueued(worker: EmbedLink, args: %{"link_id" => link.id})
    end

    test "blank clears them; another user gets not_found", %{scope: scope} do
      link = link_fixture(scope)
      {:ok, _} = Library.update_ai_notes(scope, link, %{"ai_notes" => "x"})

      assert {:ok, %Link{ai_notes: nil}} = Library.update_ai_notes(scope, link, %{"ai_notes" => "  "})
      assert {:error, :not_found} = Library.update_ai_notes(user_scope_fixture(), link, %{"ai_notes" => "y"})
    end
  end

  describe "update_image_description/3" do
    test "saves the edit, stamps edited_at and broadcasts", %{scope: scope} do
      link = link_fixture(scope)

      assert {:ok, %Link{image_description: "Um gato", image_description_edited_at: %DateTime{}}} =
               Library.update_image_description(scope, link, %{"image_description" => "  Um gato "})

      assert_receive {:link_updated, %Link{image_description: "Um gato"}}
      assert %Link{image_description_edited_at: %DateTime{}} = Repo.get!(Link, link.id)
    end

    test "another user gets not_found", %{scope: scope} do
      link = link_fixture(scope)

      assert {:error, :not_found} =
               Library.update_image_description(user_scope_fixture(), link, %{"image_description" => "x"})

      refute Repo.get!(Link, link.id).image_description
    end

    test "change_image_description/2 validates the length", %{scope: scope} do
      changeset =
        Library.change_image_description(link_fixture(scope), %{"image_description" => String.duplicate("a", 1001)})

      refute changeset.valid?
    end
  end

  describe "search embedding on edits" do
    defp embed_jobs(link), do: all_enqueued(worker: EmbedLink, args: %{"link_id" => link.id})

    defp assert_scheduled_embedding(link) do
      assert [%Oban.Job{state: "scheduled", scheduled_at: at}] = embed_jobs(link)
      assert DateTime.diff(at, DateTime.utc_now()) in 3..5
      assert %Link{embedding_status: :pending} = Repo.get!(Link, link.id)
    end

    defp settle(link) do
      Repo.delete_all(Oban.Job)
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [embedding_status: :ready])
    end

    test "a note edit enqueues it 5 seconds ahead; the same note again does not", %{scope: scope} do
      link = link_fixture(scope)

      assert {:ok, %Link{embedding_status: :pending}} = Library.update_note(scope, link, %{note: "worth reading"})
      assert_scheduled_embedding(link)

      settle(link)
      assert {:ok, _} = Library.update_note(scope, link, %{note: "worth reading"})
      assert embed_jobs(link) == []
      assert %Link{embedding_status: :ready} = Repo.get!(Link, link.id)
    end

    test "an image description edit enqueues it; the same text again does not", %{scope: scope} do
      link = link_fixture(scope)

      assert {:ok, _} = Library.update_image_description(scope, link, %{"image_description" => "Um gato"})
      assert_scheduled_embedding(link)

      settle(link)
      assert {:ok, _} = Library.update_image_description(scope, link, %{"image_description" => " Um gato "})
      assert embed_jobs(link) == []
    end

    test "a burst of edits leaves one job", %{scope: scope} do
      link = link_fixture(scope)

      for note <- ["a", "ab", "abc"], do: {:ok, _} = Library.update_note(scope, link, %{note: note})
      {:ok, _} = Library.update_image_description(scope, link, %{"image_description" => "Um gato"})

      assert [_] = embed_jobs(link)
    end

    test "an invalid edit or another user's link enqueues nothing", %{scope: scope} do
      link = link_fixture(scope)

      assert {:error, %Ecto.Changeset{}} = Library.update_note(scope, link, %{note: String.duplicate("a", 4001)})
      assert {:error, :not_found} = Library.update_note(user_scope_fixture(), link, %{note: "x"})
      assert embed_jobs(link) == []
      assert %Link{embedding_status: nil} = Repo.get!(Link, link.id)
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

    test "enqueues enrichment, even for an enriched link", %{scope: scope} do
      link = link_fixture(scope)

      Repo.update_all(from(l in Link, where: l.id == ^link.id),
        set: [enrichment_status: :ready, enriched_at: DateTime.utc_now(:second)]
      )

      assert {:ok, %Link{}} = Library.attach_screenshot(scope, link, image_fixture("photo.jpg"))

      assert_enqueued(worker: EnrichLink, args: %{"link_id" => link.id})
      assert %Link{enrichment_status: :pending} = Repo.get!(Link, link.id)
    end

    test "returns and broadcasts the link as pending, so its placeholder shows", %{scope: scope} do
      link = link_fixture(scope)
      Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [enrichment_status: :ready])

      assert {:ok, %Link{enrichment_status: :pending}} =
               Library.attach_screenshot(scope, link, image_fixture("photo.jpg"))

      id = link.id
      assert_receive {:link_updated, %Link{id: ^id, enrichment_status: :pending}}
    end

    test "enqueues nothing when the image is rejected", %{scope: scope} do
      link = link_fixture(scope)
      assert {:error, :not_an_image} = Library.attach_screenshot(scope, link, image_fixture("not_image.txt"))
      refute_enqueued(worker: EnrichLink)
    end

    @tag :capture_log
    test "rejects bytes that are not an image", %{scope: scope} do
      link = link_fixture(scope)
      assert {:error, :not_an_image} = Library.attach_screenshot(scope, link, image_fixture("not_image.txt"))
      assert Repo.aggregate(from(i in LinkImage, where: i.link_id == ^link.id), :count) == 0
    end
  end

  describe "check_embeddable/2" do
    defp stub_page(fun), do: Req.Test.stub(Acervo.Library.SafeFetch, fun)

    test "stores what the page's headers allow and broadcasts the link", %{scope: scope} do
      link = link_fixture(scope)
      stub_page(&Plug.Conn.send_resp(&1, 200, "<html></html>"))

      assert {:ok, %Link{embeddable: true}} = Library.check_embeddable(scope, link)
      assert %Link{embeddable: true} = Repo.get!(Link, link.id)
      assert_receive {:link_updated, %Link{embeddable: true}}

      stub_page(&(&1 |> Plug.Conn.put_resp_header("x-frame-options", "SAMEORIGIN") |> Plug.Conn.send_resp(200, "")))
      assert {:ok, %Link{embeddable: false}} = Library.check_embeddable(scope, link)
    end

    test "a page that won't load stores false, a transient failure nothing", %{scope: scope} do
      link = link_fixture(scope)

      stub_page(&Plug.Conn.send_resp(&1, 503, ""))
      assert {:error, {:http, 503}} = Library.check_embeddable(scope, link)
      assert %Link{embeddable: nil} = Repo.get!(Link, link.id)

      stub_page(&Plug.Conn.send_resp(&1, 404, ""))
      assert {:ok, %Link{embeddable: false}} = Library.check_embeddable(scope, link)
    end

    test "another user's link is not found", %{scope: scope} do
      link = link_fixture(user_scope_fixture())
      assert {:error, :not_found} = Library.check_embeddable(scope, link)
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

  defp insert_suggestion(scope, link, attrs, status, inserted_at) do
    %Suggestion{user_id: scope.user.id, link_id: link.id, status: status, inserted_at: inserted_at}
    |> Suggestion.changeset(attrs)
    |> Repo.insert!()
  end
end
