defmodule Acervo.ReleaseTest do
  use Acervo.DataCase, async: false
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures, only: [collection_link_image_fixture: 2]
  import Acervo.LibraryFixtures
  import ExUnit.CaptureIO

  alias Acervo.AI
  alias Acervo.Library.CaptureSnapshot
  alias Acervo.Library.Link
  alias Acervo.Release
  alias Acervo.Search.EmbedLink

  setup do
    %{scope: user_scope_fixture()}
  end

  defp link(scope, attrs) do
    link = link_fixture(scope)
    Repo.update_all(from(l in Link, where: l.id == ^link.id), set: Keyword.merge([status: :ready], attrs))
    Repo.get!(Link, link.id)
  end

  defp embedded(model), do: [embedding: Pgvector.new(List.duplicate(0.01, 1024)), embedding_model: model]

  describe "stale_embeddings/2" do
    test "picks ready links never embedded or embedded with another model", %{scope: scope} do
      model = AI.embedding_model()
      never = link(scope, [])
      failed_never = link(scope, embedding_status: :failed)
      other_model = link(scope, embedded("other:model") ++ [embedding_status: :ready])
      current = link(scope, embedded(model) ++ [embedding_status: :ready])
      current_failed = link(scope, embedded(model) ++ [embedding_status: :failed])
      pending = link(scope, embedded("other:model") ++ [embedding_status: :pending])
      capturing = link(scope, status: :pending)

      ids = Release.stale_embeddings(Repo)

      for link <- [never, failed_never, other_model], do: assert(link.id in ids)
      for link <- [current, current_failed, pending, capturing], do: refute(link.id in ids)
    end

    test "with all: true picks every ready link not pending", %{scope: scope} do
      current = link(scope, embedded(AI.embedding_model()) ++ [embedding_status: :ready])
      never = link(scope, [])
      pending = link(scope, embedding_status: :pending)

      ids = Release.stale_embeddings(Repo, all: true)

      assert current.id in ids
      assert never.id in ids
      refute pending.id in ids
    end
  end

  test "reindex/1 enqueues and marks the stale links, and returns the count", %{scope: scope} do
    stale = link(scope, embedded("other:model") ++ [embedding_status: :ready])
    current = link(scope, embedded(AI.embedding_model()) ++ [embedding_status: :ready])

    {count, output} = with_io(fn -> Release.reindex() end)

    assert count >= 1
    assert output =~ "Enqueued embedding for #{count} links."
    assert_enqueued(worker: EmbedLink, args: %{"link_id" => stale.id})
    refute_enqueued(worker: EmbedLink, args: %{"link_id" => current.id})
    assert Repo.get!(Link, stale.id).embedding_status == :pending
    assert Repo.get!(Link, current.id).embedding_status == :ready
  end

  describe "backfill_snapshots/0" do
    test "does nothing while the screenshot service is off", %{scope: scope} do
      link(scope, [])

      {count, output} = with_io(fn -> Release.backfill_snapshots() end)

      assert count == 0
      assert output =~ "Enqueued snapshots for 0 links."
      refute_enqueued(worker: CaptureSnapshot)
    end

    test "enqueues ready generic links with no card image at the lowest priority", %{scope: scope} do
      enable_snapshots()
      bare = link(scope, [])
      failed_capture = link(scope, capture_error: "http_403")
      with_preview = link(scope, [])
      collection_link_image_fixture(with_preview, %{kind: :preview})
      with_snapshot = link(scope, [])
      collection_link_image_fixture(with_snapshot, %{kind: :snapshot})
      only_content = link(scope, [])
      collection_link_image_fixture(only_content, %{kind: :content})
      capturing = link(scope, status: :pending)
      video = link(scope, source: :youtube)

      assert Enum.sort(Release.missing_snapshots(Repo)) == Enum.sort([bare.id, failed_capture.id, only_content.id])
      refute Enum.any?([with_preview, with_snapshot, capturing, video], &(&1.id in Release.missing_snapshots(Repo)))

      {count, output} = with_io(fn -> Release.backfill_snapshots() end)

      assert count == 3
      assert output =~ "Enqueued snapshots for 3 links."

      for link <- [bare, failed_capture, only_content] do
        assert_enqueued(worker: CaptureSnapshot, args: %{"link_id" => link.id, "replace" => false}, priority: 9)
      end

      assert {0, _output} = with_io(fn -> Release.backfill_snapshots() end)
    end
  end
end
