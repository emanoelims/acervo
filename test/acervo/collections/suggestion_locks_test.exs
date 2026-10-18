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
      Sandbox.unboxed_run(Repo, fn -> Repo.delete_all(from u in User, where: u.id == ^scope.user.id) end)
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
  # suggestions; accepting one must not wait for the link in turn.
  test "accepting a suggestion is not blocked by a session holding its link", %{scope: scope} do
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
    result = Task.yield(accept, 2_000)
    send(holder.pid, :release)

    assert {:ok, {:ok, %Collection{name: "Foo"}}} = result
    assert {:ok, :released} = Task.await(holder)
  end
end
