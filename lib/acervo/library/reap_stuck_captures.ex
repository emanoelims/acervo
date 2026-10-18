defmodule Acervo.Library.ReapStuckCaptures do
  @moduledoc """
  Marks captures that no job will ever finish as `:failed` with
  `capture_error: "timed out"`, and broadcasts `{:link_updated, link}`.

  A link is stuck when it has been `:processing` or `:pending` for longer
  than 30 minutes with no live (available, scheduled, retryable or
  executing) `Acervo.Library.CaptureLink` job. That happens when Oban kills
  the last attempt, by its timeout, before the worker can record the failure.
  Runs from `Oban.Plugins.Cron` every 10 minutes.
  """
  use Oban.Worker, queue: :capture, max_attempts: 3

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.Library
  alias Acervo.Library.CaptureLink
  alias Acervo.Library.Link
  alias Acervo.Repo

  @stuck_after_minutes 30
  @stuck_statuses [:processing, :pending]
  @live_job_states ~w(available scheduled retryable executing)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.shift(DateTime.utc_now(:second), minute: -@stuck_after_minutes)

    live_jobs =
      from j in Oban.Job,
        where:
          j.worker == ^Oban.Worker.to_string(CaptureLink) and j.state in @live_job_states and
            fragment("?->>'link_id' = ?::text", j.args, parent_as(:link).id)

    stuck =
      from l in Link,
        as: :link,
        where: l.status in @stuck_statuses and l.updated_at < ^cutoff and not exists(live_jobs),
        select: l

    {_count, links} =
      Repo.update_all(stuck,
        set: [status: :failed, capture_error: "timed out", updated_at: DateTime.utc_now(:second)]
      )

    links
    |> Repo.preload(:user)
    |> Enum.each(&Library.broadcast_updated(Scope.for_user(&1.user), &1.id))
  end
end
