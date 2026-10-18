defmodule Acervo.Library.ReapStuckCapturesTest do
  use Acervo.DataCase, async: true
  use Oban.Testing, repo: Acervo.Repo

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.Library
  alias Acervo.Library.CaptureLink
  alias Acervo.Library.Link
  alias Acervo.Library.ReapStuckCaptures

  setup do
    scope = user_scope_fixture()
    Library.subscribe(scope)
    %{scope: scope}
  end

  defp put_link(link, status, minutes_ago) do
    updated_at = DateTime.shift(DateTime.utc_now(:second), minute: -minutes_ago)
    Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [status: status, updated_at: updated_at])
  end

  defp finish_job(link) do
    Repo.update_all(
      from(j in Oban.Job, where: j.worker == ^Oban.Worker.to_string(CaptureLink) and j.args["link_id"] == ^link.id),
      set: [state: "discarded"]
    )
  end

  test "fails links stuck without a live job", %{scope: scope} do
    processing = link_fixture(scope)
    pending = link_fixture(scope)

    for link <- [processing, pending] do
      put_link(link, if(link == processing, do: :processing, else: :pending), 31)
      finish_job(link)
    end

    assert :ok = perform_job(ReapStuckCaptures, %{})

    for link <- [processing, pending] do
      assert %Link{status: :failed, capture_error: "timed out"} = Repo.get!(Link, link.id)
      id = link.id
      assert_receive {:link_updated, %Link{id: ^id, status: :failed, capture_error: "timed out"}}
    end
  end

  test "leaves fresh, queued and finished links alone", %{scope: scope} do
    fresh = link_fixture(scope)
    put_link(fresh, :processing, 5)
    finish_job(fresh)

    queued = link_fixture(scope)
    put_link(queued, :pending, 45)

    ready = link_fixture(scope)
    put_link(ready, :ready, 45)
    finish_job(ready)

    assert :ok = perform_job(ReapStuckCaptures, %{})

    assert %Link{status: :processing} = Repo.get!(Link, fresh.id)
    assert %Link{status: :pending} = Repo.get!(Link, queued.id)
    assert %Link{status: :ready} = Repo.get!(Link, ready.id)
    refute_receive {:link_updated, _}
  end
end
