defmodule Acervo.ReleaseTest do
  use Acervo.DataCase, async: false
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures
  import ExUnit.CaptureIO

  alias Acervo.AI
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
end
