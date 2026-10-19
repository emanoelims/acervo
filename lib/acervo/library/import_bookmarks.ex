defmodule Acervo.Library.ImportBookmarks do
  @moduledoc """
  Saves one batch of a bookmarks import (`Acervo.Library.BookmarkImports.run_batch/1`)
  and, in the same transaction, enqueues the next, until the import is done
  or stopped. Its scope comes from the import's user.

  A failed batch rolls back whole and retries; when it gives up, the import
  is marked `:failed`.
  """
  use Oban.Worker,
    queue: :import,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:import_id], states: [:available, :scheduled, :retryable]]

  alias Acervo.Library.BookmarkImports

  @impl Oban.Worker
  def timeout(_job), do: to_timeout(minute: 2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"import_id" => id}, attempt: attempt, max_attempts: max_attempts}) do
    {:ok, _progress} = BookmarkImports.run_batch(id)
    :ok
  rescue
    exception ->
      if attempt >= max_attempts, do: BookmarkImports.fail(id)
      reraise exception, __STACKTRACE__
  end
end
