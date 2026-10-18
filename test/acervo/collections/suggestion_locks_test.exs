defmodule Acervo.Collections.SuggestionLocksTest do
  # Row locks only conflict across real connections, so each process here
  # checks out its own, outside the sandbox, and the test cleans up after
  # itself.
  use ExUnit.Case, async: false

  import Acervo.AccountsFixtures
  import Acervo.CollectionsFixtures
  import Ecto.Query

  alias Acervo.Accounts.User
  alias Acervo.Collections
  alias Acervo.Collections.Collection
  alias Acervo.Collections.Suggestion
  alias Acervo.Library.Link
  alias Acervo.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    scope = user_scope_fixture()

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        # Accepting a suggestion enqueues the link's embedding, outside the sandbox.
        link_ids = from l in Link, where: l.user_id == ^scope.user.id, select: type(l.id, :string)
        Repo.delete_all(from j in Oban.Job, where: fragment("?->>'link_id'", j.args) in subquery(link_ids))
        Repo.delete_all(from u in User, where: u.id == ^scope.user.id)
      end)
    end)

    %{scope: scope}
  end

  defp in_own_connection(fun) do
    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      fun.()
    end)
  end

  test "accepting a new name skips a same-name suggestion another session holds", %{scope: scope} do
    mine = suggestion_fixture(scope, collection_link_fixture(scope), %{proposed_name: "Foo"})
    held = suggestion_fixture(scope, collection_link_fixture(scope), %{proposed_name: "Foo"})
    test = self()

    # Another session in the middle of accepting `held`.
    holder =
      in_own_connection(fn ->
        Repo.transact(fn ->
          Repo.one!(from s in Suggestion, where: s.id == ^held.id, lock: "FOR UPDATE")
          send(test, :locked)

          receive do
            :release -> {:ok, :released}
          after
            5_000 -> {:ok, :timed_out}
          end
        end)
      end)

    assert_receive :locked, 1_000

    accept = in_own_connection(fn -> Collections.accept_suggestion(scope, mine.id) end)
    result = Task.yield(accept, 2_000)
    send(holder.pid, :release)

    assert {:ok, {:ok, %Collection{name: "Foo"}}} = result
    assert {:ok, :released} = Task.await(holder)
    assert %Suggestion{status: :pending, collection_id: nil} = Repo.get!(Suggestion, held.id)
  end

  # `finish_triage/2` and enrichment hold the link while they wait for its
  # suggestions. Accepting one locks the link first too, so it waits for the
  # holder instead of holding the suggestion the holder waits for.
  test "accepting a suggestion waits for a session holding its link, then succeeds", %{scope: scope} do
    link = collection_link_fixture(scope)
    suggestion = suggestion_fixture(scope, link, %{proposed_name: "Foo"})
    test = self()

    holder =
      in_own_connection(fn ->
        Repo.transact(fn ->
          Repo.one!(from l in Link, where: l.id == ^link.id, lock: "FOR NO KEY UPDATE")
          send(test, :locked)

          receive do
            :release -> {:ok, :released}
          after
            5_000 -> {:ok, :timed_out}
          end
        end)
      end)

    assert_receive :locked, 1_000

    accept = in_own_connection(fn -> Collections.accept_suggestion(scope, suggestion.id) end)
    assert Task.yield(accept, 300) == nil

    send(holder.pid, :release)

    assert {:ok, :released} = Task.await(holder)
    assert {:ok, %Collection{name: "Foo"}} = Task.await(accept)
  end

  # The holder takes the link, then the suggestion: the order every writer
  # follows. Neither session deadlocks; the accept runs after the holder.
  test "a session finishing triage and one accepting the same suggestion do not deadlock", %{scope: scope} do
    link = collection_link_fixture(scope)
    suggestion = suggestion_fixture(scope, link, %{proposed_name: "Foo"})
    test = self()

    triage =
      in_own_connection(fn ->
        Repo.transact(fn ->
          Repo.one!(from l in Link, where: l.id == ^link.id, lock: "FOR NO KEY UPDATE")
          send(test, :locked)

          receive do
            :go -> :ok
          after
            5_000 -> :ok
          end

          Repo.update_all(from(s in Suggestion, where: s.link_id == ^link.id), set: [status: :dismissed])
          {:ok, :triaged}
        end)
      end)

    assert_receive :locked, 1_000
    accept = in_own_connection(fn -> Collections.accept_suggestion(scope, suggestion.id) end)
    assert Task.yield(accept, 300) == nil
    send(triage.pid, :go)

    assert {:ok, :triaged} = Task.await(triage)
    assert {:error, :not_found} = Task.await(accept)
    assert %Suggestion{status: :dismissed} = Repo.get!(Suggestion, suggestion.id)
  end

  test "adding a link deleted by another session is not found, not a raise", %{scope: scope} do
    collection = collection_fixture(scope, %{name: "Foo"})
    link = collection_link_fixture(scope)
    test = self()

    deleter =
      in_own_connection(fn ->
        Repo.transact(fn ->
          Repo.one!(from l in Link, where: l.id == ^link.id, lock: "FOR NO KEY UPDATE")
          send(test, :locked)

          receive do
            :go -> :ok
          after
            5_000 -> :ok
          end

          Repo.delete_all(from l in Link, where: l.id == ^link.id)
          {:ok, :deleted}
        end)
      end)

    assert_receive :locked, 1_000
    add = in_own_connection(fn -> Collections.add_link(scope, collection, link) end)
    assert Task.yield(add, 300) == nil
    send(deleter.pid, :go)

    assert {:ok, :deleted} = Task.await(deleter)
    assert {:error, :not_found} = Task.await(add)
  end
end
