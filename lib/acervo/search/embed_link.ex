defmodule Acervo.Search.EmbedLink do
  @moduledoc """
  Embeds a link's searchable text (`Acervo.Search.Document`) with the
  configured embedding model and stores the vector on the link.

  Enqueued whenever that text changes: when enrichment finishes (whatever
  its outcome), on a re-capture of an enriched link, when the reader content
  is backfilled, and when the owner edits the note or the image description,
  adds or removes the link from a collection, or renames or deletes one of
  its collections. Owner edits wait 5 seconds, so a burst of them collapses
  into the one scheduled job.

  The link's `embedding_status` follows the job: `:pending` once enqueued,
  `:ready` when stored, `:failed` when the job gives up, and back to nil when
  the link is not captured or has nothing to embed.

  A document whose digest (`Acervo.Search.Document.digest/2`) matches the
  stored one, for the same model, is not embedded again: repeated triggers
  and reindexing cost nothing.

  ## Changes during a run

  A job that is executing does not block a new one (`executing` is not among
  the unique states), so an edit made during the call queues a fresh job.
  Before storing, the run locks the link, rebuilds the document and compares
  digests. When the text changed during the call, the stale vector is not
  stored; the link stays `:pending` and the run enqueues the link again.
  That enqueue conflicts with the edit's own job when there is one, and
  otherwise covers a change no enqueue point saw.

  ## Errors

  See `Acervo.AI.Client`:

    * Rate limits snooze the job with a backoff of our own. After 5 snoozes
      the limit counts as a transient error.
    * Timeouts, 408, 409, 5xx and provider errors retry; the last attempt
      marks the link `:failed`.
    * A missing key, every other 4xx and an invalid response (a vector of
      the wrong length is a configuration error) cancel the job and mark the
      link `:failed`.
    * An exception is logged by type only and handled as transient.
  """
  use Oban.Worker,
    queue: :embed,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:link_id], states: [:available, :scheduled, :retryable]]

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.AI
  alias Acervo.Library.Link
  alias Acervo.Repo
  alias Acervo.Search.Document

  require Logger

  @max_snoozes 5
  @chunk_size 200
  @min_snooze 15
  @max_snooze 600
  @default_snooze 60

  @doc """
  Marks the link `:pending` (on the link row only, `updated_at` untouched)
  and enqueues its embedding, in one transaction: the mark lands before any
  job can finish. When a job for the link is already waiting, Oban returns it
  with `conflict?: true` and the link is still `:pending`. Call it inside the
  transaction that changed the embedded text, if there is one.

  ## Options

    * `:delay` - seconds to wait before running, for owner edits
    * `:oban` - the Oban instance, `Oban` by default
  """
  @spec enqueue(Link.t() | Ecto.UUID.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(link, opts \\ [])

  def enqueue(%Link{id: link_id}, opts), do: enqueue(link_id, opts)

  def enqueue(link_id, opts) when is_binary(link_id) do
    Repo.transact(fn ->
      Repo.update_all(from(l in Link, where: l.id == ^link_id), set: [embedding_status: :pending])
      insert(link_id, opts)
    end)
  end

  @doc """
  `enqueue/2` for many links, in transactions of 200 ids walked in
  the order given (callers pass newest first, so the newest links are marked
  and scheduled first). Inside a chunk the rows are locked in id order, so
  concurrent bulk enqueues cannot deadlock; each is marked `:pending` and gets
  one job. A failure rolls back its own chunk only, earlier chunks stay
  enqueued. Returns how many links were enqueued.

  ## Options

  Those of `enqueue/2`, and `:chunk_size` (200 by default).
  """
  @spec enqueue_many([Ecto.UUID.t()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def enqueue_many(link_ids, opts \\ []) when is_list(link_ids) do
    link_ids
    |> Enum.uniq()
    |> Enum.chunk_every(Keyword.get(opts, :chunk_size, @chunk_size))
    |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, total} ->
      case enqueue_chunk(chunk, opts) do
        {:ok, count} -> {:cont, {:ok, total + count}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp enqueue_chunk(chunk, opts) do
    Repo.transact(fn ->
      ids =
        Repo.all(
          from l in Link,
            where: l.id in ^chunk,
            order_by: l.id,
            lock: "FOR NO KEY UPDATE",
            select: l.id
        )

      Repo.update_all(from(l in Link, where: l.id in ^ids), set: [embedding_status: :pending])
      insert_each(ids, opts)
    end)
  end

  # The Basic engine's `insert_all` ignores uniqueness: one insert each.
  defp insert_each(ids, opts) do
    Enum.reduce_while(ids, {:ok, 0}, fn id, {:ok, count} ->
      case insert(id, opts) do
        {:ok, _job} -> {:cont, {:ok, count + 1}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp insert(link_id, opts) do
    job_opts =
      case Keyword.get(opts, :delay, 0) do
        delay when is_integer(delay) and delay > 0 -> [schedule_in: delay]
        _ -> []
      end

    Oban.insert(Keyword.get(opts, :oban, Oban), new(%{"link_id" => link_id}, job_opts))
  end

  @impl Oban.Worker
  def timeout(_job), do: to_timeout(second: 30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"link_id" => link_id}} = job) do
    case load(link_id) do
      {:ok, scope, link, stored} -> embed(job, scope, link, stored)
      :error -> :ok
    end
  end

  # The worker has no session: the scope is the link owner's.
  defp load(link_id) do
    with {:ok, id} <- Ecto.UUID.cast(link_id),
         {%Link{} = link, digest, embedded?} <-
           Repo.one(
             from l in Link,
               where: l.id == ^id,
               preload: :user,
               select: {l, l.embedding_digest, not is_nil(l.embedding)}
           ) do
      {:ok, Scope.for_user(link.user), link, %{digest: digest, embedded?: embedded?}}
    else
      _ -> :error
    end
  end

  # A link that is not ready is captured later, and its capture enqueues
  # the embedding again.
  defp embed(_job, _scope, %Link{status: status} = link, _stored) when status != :ready, do: reset(link)

  defp embed(job, scope, link, stored) do
    model = AI.embedding_model()

    case Document.build(scope, link) do
      :skip ->
        clear(scope, link)

      {:ok, text} ->
        digest = Document.digest(model, text)

        if stored.embedded? and stored.digest == digest and link.embedding_model == model,
          do: mark_ready(link, digest),
          else: call(job, scope, link, text, digest)
    end
  rescue
    exception -> crashed(job, link, exception, __STACKTRACE__)
  end

  defp call(job, scope, link, text, digest) do
    meta = %{operation: "embed_link", link_id: link.id}

    with {:ok, vector} <- AI.embed(scope, meta, text, input_type: :document),
         :ok <- check_length(vector) do
      store(scope, link, digest, vector)
    else
      {:error, reason} -> failed(job, link, reason)
    end
  end

  defp check_length(vector) do
    if length(vector) == AI.embedding_dimensions(), do: :ok, else: {:error, :invalid_response}
  end

  ## Success

  defp store(scope, link, digest, vector) do
    {:ok, _result} = Repo.transact(fn -> store_locked(scope, link, digest, vector) end)
    :ok
  end

  defp store_locked(scope, link, digest, vector) do
    model = AI.embedding_model()

    with %Link{} = fresh <- lock_link(scope, link.id),
         {:ok, text} <- Document.build(scope, fresh),
         ^digest <- Document.digest(model, text) do
      fresh
      |> Link.embedding_changeset(%{
        embedding: Pgvector.new(vector),
        embedding_model: model,
        embedding_digest: digest,
        embedding_status: :ready,
        embedded_at: DateTime.utc_now(:second)
      })
      |> Repo.update()
    else
      # Deleted during the call.
      nil -> {:ok, :gone}
      # The text changed during the call: this vector is stale.
      _changed -> enqueue(link.id)
    end
  end

  # Same lock as every other writer of the link, ownership checked.
  defp lock_link(%Scope{user: user}, link_id) do
    Repo.one(from l in Link, where: l.id == ^link_id and l.user_id == ^user.id, lock: "FOR NO KEY UPDATE")
  end

  defp mark_ready(link, digest) do
    Repo.update_all(from(l in Link, where: l.id == ^link.id and l.embedding_digest == ^digest),
      set: [embedding_status: :ready]
    )

    :ok
  end

  ## Nothing to do

  defp reset(link) do
    Repo.update_all(from(l in Link, where: l.id == ^link.id and l.embedding_status == :pending),
      set: [embedding_status: nil]
    )

    :ok
  end

  # Nothing is left to embed (say, the only note was removed): drop the old
  # vector, unless the text came back meanwhile.
  defp clear(scope, link) do
    {:ok, _result} =
      Repo.transact(fn ->
        with %Link{} = fresh <- lock_link(scope, link.id),
             :skip <- Document.build(scope, fresh) do
          Repo.update_all(from(l in Link, where: l.id == ^fresh.id),
            set: [embedding: nil, embedding_model: nil, embedding_digest: nil, embedded_at: nil, embedding_status: nil]
          )

          {:ok, :cleared}
        else
          nil -> {:ok, :gone}
          {:ok, _text} -> enqueue(link.id)
        end
      end)

    :ok
  end

  ## Errors

  defp failed(job, link, {:rate_limited, retry_after}) do
    snoozed = job.meta["snoozed"] || 0

    if snoozed < @max_snoozes do
      {:snooze, snooze_seconds(retry_after, snoozed)}
    else
      transient(job, link, {:rate_limited, retry_after})
    end
  end

  defp failed(_job, link, :invalid_response) do
    Logger.error(
      "embedding of link #{link.id} got no valid #{AI.embedding_dimensions()}-dimension vector " <>
        "from #{AI.embedding_model()}"
    )

    give_up(link, {:cancel, :invalid_response})
  end

  defp failed(job, link, reason) do
    case AI.Client.classify(reason) do
      :transient -> transient(job, link, reason)
      :permanent -> give_up(link, {:cancel, reason})
    end
  end

  # ReqLLM drops `retry-after`, so without it the wait doubles per snooze.
  defp snooze_seconds(retry_after, snoozed) do
    (retry_after || @default_snooze * Integer.pow(2, snoozed)) |> max(@min_snooze) |> min(@max_snooze)
  end

  defp transient(%Oban.Job{attempt: attempt, max_attempts: max}, link, reason) do
    if attempt >= max, do: give_up(link, {:error, reason}), else: {:error, reason}
  end

  defp give_up(link, result) do
    Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [embedding_status: :failed])
    result
  end

  defp crashed(job, link, exception, stacktrace) do
    # The exception's type and arities only: its message and the call
    # arguments could carry page content.
    stacktrace =
      Enum.map(stacktrace, fn
        {module, fun, args, location} when is_list(args) -> {module, fun, length(args), location}
        entry -> entry
      end)

    Logger.error(
      "embedding of link #{link.id} crashed with #{inspect(exception.__struct__)}\n" <>
        Exception.format_stacktrace(stacktrace)
    )

    transient(job, link, :crashed)
  end
end
