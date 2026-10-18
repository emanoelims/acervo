defmodule Acervo.Library.ReapStuckCaptures do
  @moduledoc """
  Marks captures that no job will ever finish as `:failed` with
  `capture_error: "timed out"`, and broadcasts `{:link_updated, link}`.

  A link is stuck when it has been `:processing` or `:pending` for longer
  than 30 minutes with no live (available, scheduled, retryable or
  executing) `Acervo.Library.CaptureLink` job. That happens when Oban kills
  the last attempt, by its timeout, before the worker can record the failure.

  A second pass does the same for enrichment: a link `enrichment_status:
  :pending` for longer than 30 minutes with no live `Acervo.AI.EnrichLink`
  job becomes `enrichment_status: :failed`. The capture is left alone.

  A third pass does the same for search embeddings: a link
  `embedding_status: :pending` for longer than 30 minutes with no live
  `Acervo.Search.EmbedLink` job becomes `embedding_status: :failed`.

  Runs from `Oban.Plugins.Cron` every 10 minutes.
  """
  use Oban.Worker, queue: :capture, max_attempts: 3

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.AI.EnrichLink
  alias Acervo.Library
  alias Acervo.Library.CaptureLink
  alias Acervo.Library.Link
  alias Acervo.Repo
  alias Acervo.Search.EmbedLink

  @stuck_after_minutes 30
  @stuck_statuses [:processing, :pending]
  @live_job_states ~w(available scheduled retryable executing)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.shift(DateTime.utc_now(:second), minute: -@stuck_after_minutes)
    reap_captures(cutoff)
    reap_enrichments(cutoff)
    reap_embeddings(cutoff)
    :ok
  end

  defp reap_captures(cutoff) do
    stuck =
      from l in Link,
        as: :link,
        where: l.status in @stuck_statuses and l.updated_at < ^cutoff and not exists(live_jobs(CaptureLink)),
        select: l

    stuck
    |> Repo.update_all(set: [status: :failed, capture_error: "timed out", updated_at: DateTime.utc_now(:second)])
    |> broadcast()
  end

  defp reap_enrichments(cutoff) do
    stuck =
      from l in Link,
        as: :link,
        where: l.enrichment_status == :pending and l.updated_at < ^cutoff and not exists(live_jobs(EnrichLink)),
        select: l

    stuck |> Repo.update_all(set: [enrichment_status: :failed]) |> broadcast()
  end

  # Nothing visible changes, so nothing is broadcast.
  defp reap_embeddings(cutoff) do
    stuck =
      from l in Link,
        as: :link,
        where: l.embedding_status == :pending and l.updated_at < ^cutoff and not exists(live_jobs(EmbedLink))

    Repo.update_all(stuck, set: [embedding_status: :failed])
  end

  defp live_jobs(worker) do
    from j in Oban.Job,
      where:
        j.worker == ^Oban.Worker.to_string(worker) and j.state in @live_job_states and
          fragment("?->>'link_id' = ?::text", j.args, parent_as(:link).id)
  end

  defp broadcast({_count, links}) do
    links
    |> Repo.preload(:user)
    |> Enum.each(&Library.broadcast_updated(Scope.for_user(&1.user), &1.id))
  end
end
