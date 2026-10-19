defmodule Acervo.Library.CaptureSnapshot do
  @moduledoc """
  Takes a screenshot of a link's page with `Acervo.Library.Screenshots` and
  stores it as the link's first card image, of kind `:snapshot`.

  Enqueued by `Acervo.Library.CaptureLink` when a generic link's capture ends
  with no card image (`replace: false`), by `Acervo.Library.request_snapshot/2`
  when the user asks for a new image (`replace: true`), and by
  `Acervo.Release.backfill_snapshots/0`. A job that does not replace skips
  the screenshot when the link already has a card image.

  The page is the link's resolved URL, else its canonical one. The JPEG is
  normalized like any captured image and stored at position 0 in one
  transaction that deletes the link's earlier snapshots and moves its other
  card images down; uploads and previews are never removed. The link is then
  broadcast as `{:link_updated, link}`.

  Errors follow `Acervo.Library.Screenshots.classify/1`: a busy service
  snoozes the job (at most 10 times, then it counts as transient),
  transient errors retry and permanent ones (and an image that does not
  normalize) cancel it.

  ## Enrichment

  The capture leaves enrichment to this job, so the model sees the image and
  is paid once. When the job ends, whatever the outcome (stored, skipped,
  cancelled or failed on its last attempt), a link that was never enriched
  is enqueued for `Acervo.AI.EnrichLink` at the job's priority. A requested
  snapshot of an enriched link re-enriches it, as an uploaded screenshot
  does: the image changed. Search embeddings are left alone, since images
  are not embedded; enrichment re-embeds the link when it finishes.

  Every finished job broadcasts `{:link_updated, link}`; a requested
  snapshot that fails for good also broadcasts `{:snapshot_failed, link}`,
  so the open link can say so.
  """
  use Oban.Worker,
    queue: :snapshot,
    max_attempts: 3,
    unique: [period: 60, keys: [:link_id, :replace], states: [:available, :scheduled, :executing, :retryable]]

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.AI.EnrichLink
  alias Acervo.Library
  alias Acervo.Library.Embed
  alias Acervo.Library.Images
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage
  alias Acervo.Library.Screenshots
  alias Acervo.Repo
  alias Acervo.Storage

  require Logger

  @max_snoozes 10
  @busy_snooze 30

  @doc """
  Enqueues a snapshot of `link`. `:replace` (false by default) takes a new
  one even when the link has a card image; `:priority` (0 by default) is the
  job's Oban priority, which its enrichment inherits.
  """
  @spec enqueue(Link.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%Link{id: link_id}, opts \\ []) do
    opts = Keyword.validate!(opts, replace: false, priority: 0)

    %{"link_id" => link_id, "replace" => opts[:replace]}
    |> new(priority: opts[:priority])
    |> Oban.insert()
  end

  @impl Oban.Worker
  def timeout(_job), do: to_timeout(minute: 2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"link_id" => link_id} = args} = job) do
    replace? = args["replace"] == true

    case load(link_id) do
      {:ok, scope, link} -> snapshot(job, scope, link, replace?)
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

  defp snapshot(job, scope, link, replace?) do
    if not replace? and card_image?(link),
      do: finish(job, scope, link, replace?, :skipped),
      else: shoot(job, scope, link, replace?)
  end

  defp card_image?(link) do
    Repo.exists?(from i in LinkImage, where: i.link_id == ^link.id and i.kind in ^LinkImage.card_kinds())
  end

  defp shoot(job, scope, link, replace?) do
    with {:ok, jpeg} <- Screenshots.take(Embed.original_url(link)),
         {:ok, image} <- Images.normalize(jpeg),
         {:ok, _image} <- store(scope, link, image) do
      finish(job, scope, link, replace?, :stored)
    else
      {:error, :gone} -> :ok
      {:error, reason} -> failed(job, scope, link, replace?, reason)
    end
  end

  defp store(scope, link, image) do
    Repo.transact(fn ->
      case Repo.one(from l in Link, where: l.id == ^link.id, lock: "FOR UPDATE", select: l.id) do
        nil ->
          {:error, :gone}

        _id ->
          card_images = from i in LinkImage, where: i.link_id == ^link.id and i.kind != :content
          Repo.delete_all(where(card_images, [i], i.kind == :snapshot))
          Repo.update_all(card_images, inc: [position: 1])
          Storage.put(scope, link, Map.merge(image, %{kind: :snapshot, position: 0}))
      end
    end)
  end

  ## Errors

  defp failed(job, scope, link, replace?, :busy) do
    if (job.meta["snoozed"] || 0) < @max_snoozes,
      do: {:snooze, @busy_snooze},
      else: transient(job, scope, link, replace?, :busy)
  end

  defp failed(job, scope, link, replace?, reason) do
    Logger.warning("snapshot of link #{link.id} failed: #{describe(reason)}")

    case classify(reason) do
      :transient -> transient(job, scope, link, replace?, reason)
      :permanent -> finish(job, scope, link, replace?, {:cancel, reason})
    end
  end

  # Normalization and storage failures will not change on retry.
  defp classify(reason) when reason in [:not_an_image, :too_large], do: :permanent
  defp classify(%Ecto.Changeset{}), do: :permanent
  defp classify(reason), do: Screenshots.classify(reason)

  defp transient(%Oban.Job{attempt: attempt, max_attempts: max} = job, scope, link, replace?, reason) do
    if attempt >= max,
      do: finish(job, scope, link, replace?, {:error, reason}),
      else: {:error, reason}
  end

  defp describe(%Ecto.Changeset{}), do: "invalid image"
  defp describe(reason), do: inspect(reason)

  ## The end of the job

  # Runs once, whatever the outcome: hands the link to enrichment and tells
  # the user about a requested snapshot.
  defp finish(job, scope, link, replace?, outcome) do
    enrich(link, replace?, outcome, job.priority || 0)
    notify(scope, link, replace?, outcome)

    case outcome do
      outcome when outcome in [:stored, :skipped] -> :ok
      failure -> failure
    end
  end

  defp enrich(%Link{enriched_at: nil} = link, _replace?, _outcome, priority), do: enqueue_enrichment(link, priority)
  defp enrich(link, true, :stored, priority), do: enqueue_enrichment(link, priority)
  defp enrich(_link, _replace?, _outcome, _priority), do: :ok

  defp enqueue_enrichment(link, priority) do
    case EnrichLink.enqueue(link, priority: priority) do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.error("could not enqueue enrichment of link #{link.id}: #{inspect(reason)}")
    end
  end

  # Broadcast after enrichment is enqueued, so the link arrives `:pending`.
  defp notify(scope, link, replace?, outcome) do
    Library.broadcast_updated(scope, link.id)
    if replace? and outcome not in [:stored, :skipped], do: Library.broadcast_snapshot_failed(scope, link.id)
    :ok
  end
end
