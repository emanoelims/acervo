defmodule Acervo.AI.EnrichLink do
  @moduledoc """
  Enriches a captured link with one Claude call (`Acervo.AI.Enrichment`): the
  description of its first image, its language and one to three collection
  suggestions. Enqueued after a capture, after a screenshot, after the
  reader view fills a never-enriched link, and by
  `Acervo.Release.backfill_enrichment/0`.

  The link's `enrichment_status` follows the job: `:pending` once enqueued,
  `:ready` when stored, `:failed` when the job gives up and back to nil when
  the link has nothing to read. Enrichment is never required: a failure
  leaves `status`, `triaged_at` and the card alone, and the UI shows no chips.

  Results are stored in one transaction. An image description the owner
  edited is never overwritten, and a link already triaged gets its image
  description and language but no suggestions. Every finished run broadcasts
  `{:link_updated, link}`.

  Every terminal outcome (stored, nothing to read, given up) enqueues
  `Acervo.Search.EmbedLink`, so each link is embedded once enrichment has
  had its say; a transient retry does not.

  Errors (see `Acervo.AI.Client`):

    * Rate limits snooze the job with a backoff of our own, because ReqLLM
      drops the `retry-after` header. After 5 snoozes the limit counts as
      a transient error.
    * Timeouts, 408, 409, 5xx (529 included), provider and invalid responses
      retry; the last attempt marks the link `:failed`.
    * A missing key and every other 4xx cancel the job and mark the link
      `:failed`.
    * An exception is logged by type only and handled as transient.
  """
  use Oban.Worker,
    queue: :ai,
    max_attempts: 4,
    unique: [period: :infinity, keys: [:link_id], states: [:available, :scheduled, :retryable]]

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.AI
  alias Acervo.AI.Enrichment
  alias Acervo.Collections
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
  Marks `link` `:pending` (on the link row only, `updated_at` untouched) and
  enqueues its enrichment, in one transaction: the mark lands before any job
  can finish. When a job for the link is already waiting, Oban returns it
  with `conflict?: true` and the link is still `:pending`. Call it inside the
  transaction that changed what the model reads, if there is one.

  `:priority` (0 by default) is the job's Oban priority.
  """
  @spec enqueue(Link.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t() | term()}
  def enqueue(%Link{id: link_id}, opts \\ []) do
    Repo.transact(fn ->
      Repo.update_all(from(l in Link, where: l.id == ^link_id), set: [enrichment_status: :pending])
      Oban.insert(new(%{"link_id" => link_id}, priority: Keyword.get(opts, :priority, 0)))
    end)
  end

  @impl Oban.Worker
  def timeout(_job), do: to_timeout(second: 90)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"link_id" => link_id}} = job) do
    case load(link_id) do
      {:ok, scope, link} -> enrich(job, scope, link)
      :error -> :ok
    end
  end

  defp load(link_id) do
    with {:ok, id} <- Ecto.UUID.cast(link_id),
         %Link{} = link <- Link |> Repo.get(id) |> Repo.preload(:user) do
      {:ok, Scope.for_user(link.user), link}
    else
      _ -> :error
    end
  end

  # A link that is not ready is captured (and enriched) later; there is
  # nothing to read now.
  defp enrich(_job, scope, %Link{status: status} = link) when status != :ready, do: reset(scope, link)

  defp enrich(job, scope, link) do
    case Enrichment.build_input(scope, link) do
      :skip -> reset(scope, link)
      {:ok, input} -> call(job, scope, link, input)
    end
  rescue
    exception -> crashed(job, scope, link, exception, __STACKTRACE__)
  end

  defp call(job, scope, link, input) do
    meta = %{operation: "enrich_link", link_id: link.id}

    with {:ok, object} <- AI.generate_object(scope, meta, Enrichment.context(input), Enrichment.schema()),
         {:ok, output} <- Enrichment.normalize(object, input) do
      store(scope, link, input, output)
    else
      {:error, reason} -> failed(job, scope, link, reason)
    end
  end

  ## Success

  defp store(scope, link, input, output) do
    case Repo.transact(fn -> store_output(scope, link, input, output) end) do
      {:ok, _} ->
        Library.broadcast_updated(scope, link.id)
        :ok

      # The link was deleted during the call.
      {:error, :not_found} ->
        :ok
    end
  end

  defp store_output(scope, link, input, output) do
    # Same lock as `Acervo.Collections.finish_triage/2`, so a link triaged
    # meanwhile is seen as triaged.
    case Repo.one(from l in Link, where: l.id == ^link.id and l.user_id == ^scope.user.id, lock: "FOR NO KEY UPDATE") do
      nil -> {:error, :not_found}
      %Link{} = fresh -> update_and_suggest(scope, fresh, input, output)
    end
  end

  defp update_and_suggest(scope, link, input, output) do
    attrs = %{language: output.language, enriched_at: DateTime.utc_now(:second), enrichment_status: :ready}

    # The owner's edit always wins.
    attrs =
      if is_nil(link.image_description_edited_at),
        do: Map.put(attrs, :image_description, output.image_description),
        else: attrs

    with {:ok, link} <- link |> Link.enrichment_changeset(attrs) |> Repo.update(),
         {:ok, _suggestions} <- suggest(scope, link, input, output),
         {:ok, _job} <- EmbedLink.enqueue(link) do
      {:ok, link}
    end
  end

  # Triaged links are out of the inbox: no new suggestions for them.
  defp suggest(_scope, %Link{triaged_at: %DateTime{}}, _input, _output), do: {:ok, []}

  defp suggest(scope, link, input, output) do
    ids = Map.new(input.collections, &{&1.slug, &1.id})
    Collections.replace_suggestions(scope, link, Enum.flat_map(output.suggestions, &entry(&1, ids)))
  end

  defp entry(%{collection_slug: slug, reason: reason}, ids) do
    case ids do
      %{^slug => id} -> [%{collection_id: id, reason: reason}]
      %{} -> []
    end
  end

  defp entry(%{proposed_name: name, reason: reason}, _ids), do: [%{proposed_name: name, reason: reason}]

  ## Nothing to do

  defp reset(scope, link) do
    Repo.update_all(from(l in Link, where: l.id == ^link.id and l.enrichment_status == :pending),
      set: [enrichment_status: nil]
    )

    embed(link)
    Library.broadcast_updated(scope, link.id)
    :ok
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
    Repo.update_all(from(l in Link, where: l.id == ^link.id), set: [enrichment_status: :failed])
    embed(link)
    Library.broadcast_updated(scope, link.id)
    result
  end

  # The search embedding does not wait for a successful enrichment.
  defp embed(link) do
    case EmbedLink.enqueue(link) do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.error("could not enqueue embedding of link #{link.id}: #{inspect(reason)}")
    end
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
      "enrichment of link #{link.id} crashed with #{inspect(exception.__struct__)}\n" <>
        Exception.format_stacktrace(stacktrace)
    )

    transient(job, scope, link, :crashed)
  end
end
