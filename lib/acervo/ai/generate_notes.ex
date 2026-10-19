defmodule Acervo.AI.GenerateNotes do
  @moduledoc """
  Writes a link's AI notes with one Claude call (`Acervo.AI.Notes`): a short
  summary and 3 to 7 key points in Portuguese, stored as editable text in
  `ai_notes`, with `ai_notes_at`. Each run replaces the link's AI notes,
  edited or not, and never touches the owner's note.

  Enqueued when the owner asks (`Acervo.Library.request_notes/2`) and, by
  the user's `auto_notes` setting, after enrichment (`enqueue_auto/3`). The
  call is recorded in `ai_calls` as `generate_notes`. A stored run embeds
  the link again (`Acervo.Search.EmbedLink`), since the notes are part of
  its search text, and broadcasts `{:link_updated, link}`.

  Errors (see `Acervo.AI.Client`), as in `Acervo.AI.EnrichLink`: rate limits
  snooze up to 5 times, transient errors retry, permanent ones cancel. When
  the job gives up, or the link has nothing to read, the scope's topic gets
  `{:notes_failed, link}`.
  """
  use Oban.Worker,
    queue: :ai,
    max_attempts: 4,
    unique: [period: :infinity, keys: [:link_id], states: [:available, :scheduled, :retryable]]

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.AI
  alias Acervo.AI.Notes
  alias Acervo.Library
  alias Acervo.Library.Link
  alias Acervo.Repo
  alias Acervo.Search.EmbedLink

  require Logger

  @max_snoozes 5
  @min_snooze 15
  @max_snooze 600
  @default_snooze 60

  @doc """
  Enqueues the link's notes. When a job for the link is already waiting,
  Oban returns it with `conflict?: true`. `:priority` (0 by default) is the
  job's Oban priority.
  """
  @spec enqueue(Link.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t() | term()}
  def enqueue(%Link{id: link_id}, opts \\ []) do
    Oban.insert(new(%{"link_id" => link_id}, priority: Keyword.get(opts, :priority, 0)))
  end

  @doc """
  Enqueues automatic notes after enrichment, when the user's `auto_notes`
  setting asks for them (`Acervo.AI.Notes.auto?/2` on the article `text`)
  and the link has none yet. Returns `{:ok, :skipped}` otherwise.
  """
  @spec enqueue_auto(Scope.t(), Link.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t() | :skipped} | {:error, term()}
  def enqueue_auto(%Scope{user: user}, %Link{} = link, text, opts \\ []) do
    if is_nil(link.ai_notes) and is_nil(link.ai_notes_at) and Notes.auto?(user.auto_notes, text),
      do: enqueue(link, opts),
      else: {:ok, :skipped}
  end

  @impl Oban.Worker
  def timeout(_job), do: to_timeout(second: 90)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"link_id" => link_id}} = job) do
    with {:ok, id} <- Ecto.UUID.cast(link_id),
         %Link{} = link <- Link |> Repo.get(id) |> Repo.preload(:user) do
      write(job, Scope.for_user(link.user), link)
    else
      _ -> :ok
    end
  end

  defp write(job, scope, link) do
    case Notes.build_input(scope, link) do
      :skip -> give_up(scope, link, :ok)
      {:ok, input} -> call(job, scope, link, input)
    end
  rescue
    exception -> crashed(job, scope, link, exception, __STACKTRACE__)
  end

  defp call(job, scope, link, input) do
    meta = %{operation: "generate_notes", link_id: link.id}

    with {:ok, object} <- AI.generate_object(scope, meta, Notes.context(input), Notes.schema()),
         {:ok, output} <- Notes.normalize(object) do
      store(scope, link, Notes.render(output))
    else
      {:error, reason} -> failed(job, scope, link, reason)
    end
  end

  ## Success

  defp store(scope, link, text) do
    case Repo.transact(fn -> store_locked(scope, link, text) end) do
      {:ok, _link} ->
        Library.broadcast_updated(scope, link.id)
        :ok

      # The link was deleted during the call.
      {:error, :not_found} ->
        :ok
    end
  end

  defp store_locked(%Scope{user: user}, link, text) do
    case Repo.one(from l in Link, where: l.id == ^link.id and l.user_id == ^user.id, lock: "FOR NO KEY UPDATE") do
      nil ->
        {:error, :not_found}

      %Link{} = fresh ->
        with {:ok, updated} <-
               fresh
               |> Link.generated_notes_changeset(%{ai_notes: text, ai_notes_at: DateTime.utc_now(:second)})
               |> Repo.update(),
             {:ok, _job} <- EmbedLink.enqueue(updated) do
          {:ok, updated}
        end
    end
  end

  ## Errors

  defp failed(job, scope, link, {:rate_limited, retry_after}) do
    snoozed = job.meta["snoozed"] || 0

    if snoozed < @max_snoozes do
      {:snooze, snooze_seconds(retry_after, snoozed)}
    else
      transient(job, scope, link, {:rate_limited, retry_after})
    end
  end

  defp failed(job, scope, link, reason) do
    case AI.Client.classify(reason) do
      :transient -> transient(job, scope, link, reason)
      :permanent -> give_up(scope, link, {:cancel, reason})
    end
  end

  # ReqLLM drops `retry-after`, so without it the wait doubles per snooze.
  defp snooze_seconds(retry_after, snoozed) do
    (retry_after || @default_snooze * Integer.pow(2, snoozed)) |> max(@min_snooze) |> min(@max_snooze)
  end

  defp transient(%Oban.Job{attempt: attempt, max_attempts: max}, scope, link, reason) do
    if attempt >= max, do: give_up(scope, link, {:error, reason}), else: {:error, reason}
  end

  defp give_up(scope, link, result) do
    Library.broadcast_notes_failed(scope, link.id)
    result
  end

  defp crashed(job, scope, link, exception, stacktrace) do
    # The exception's type and arities only: its message and the call
    # arguments could carry page content.
    stacktrace =
      Enum.map(stacktrace, fn
        {module, fun, args, location} when is_list(args) -> {module, fun, length(args), location}
        entry -> entry
      end)

    Logger.error(
      "notes for link #{link.id} crashed with #{inspect(exception.__struct__)}\n" <>
        Exception.format_stacktrace(stacktrace)
    )

    transient(job, scope, link, :crashed)
  end
end
