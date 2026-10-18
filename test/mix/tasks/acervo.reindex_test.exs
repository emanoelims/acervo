defmodule Mix.Tasks.Acervo.ReindexTest do
  use Acervo.DataCase, async: false
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures
  import ExUnit.CaptureIO

  alias Acervo.AI
  alias Acervo.Library.Link
  alias Acervo.Search.EmbedLink

  defp ready(link, attrs) do
    Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [status: :ready] ++ attrs)
    link
  end

  test "enqueues stale links, and every ready link with --all" do
    scope = user_scope_fixture()
    stale = scope |> link_fixture() |> ready([])

    current =
      scope
      |> link_fixture()
      |> ready(
        embedding: Pgvector.new(List.duplicate(0.01, 1024)),
        embedding_model: AI.embedding_model(),
        embedding_status: :ready
      )

    assert capture_io(fn -> Mix.Task.rerun("acervo.reindex") end) =~ "Enqueued embedding for"
    assert_enqueued(worker: EmbedLink, args: %{"link_id" => stale.id})
    refute_enqueued(worker: EmbedLink, args: %{"link_id" => current.id})

    capture_io(fn -> Mix.Task.rerun("acervo.reindex", ["--all"]) end)
    assert_enqueued(worker: EmbedLink, args: %{"link_id" => current.id})
  end
end
