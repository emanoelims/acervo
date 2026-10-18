defmodule Acervo.Library.ExtractContent do
  @moduledoc """
  Fills a generic link's reader view (`Acervo.Library.Reader`) by fetching
  its page again, for links captured before capture kept it. Enqueued by
  `Acervo.Release.backfill_reader_content/0`.

  Only the reader content and its images change: the title, description,
  note, collections and preview images stay as they are. Running it again
  replaces the previous content and content images.

  A page that can't be fetched for good (see
  `Acervo.Library.CaptureLink.classify/1`) is recorded as having no content;
  other errors retry.
  """
  use Oban.Worker, queue: :content, max_attempts: 3, unique: [period: 300, keys: [:link_id]]

  alias Acervo.Accounts.Scope
  alias Acervo.AI.EnrichLink
  alias Acervo.Library
  alias Acervo.Library.CaptureLink
  alias Acervo.Library.Embed
  alias Acervo.Library.Extractors.Generic
  alias Acervo.Library.Link
  alias Acervo.Library.Reader
  alias Acervo.Repo

  require Logger

  @content_ms 150_000

  @impl Oban.Worker
  def timeout(_job), do: to_timeout(minute: 3)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"link_id" => link_id}}) do
    deadline = System.monotonic_time(:millisecond) + @content_ms

    with {:ok, id} <- Ecto.UUID.cast(link_id),
         %Link{source: :generic} = link <- Link |> Repo.get(id) |> Repo.preload(:user) do
      scope = Scope.for_user(link.user)
      result = extract(scope, link, deadline)
      Library.broadcast_updated(scope, link.id)
      result
    else
      _ -> :ok
    end
  end

  defp extract(scope, link, deadline) do
    with {:ok, uri} <- parse(Embed.original_url(link)),
         {:ok, capture, final_url} <- Generic.fetch_page(uri, []) do
      content = Reader.build(capture.document, final_url, deadline: deadline)
      scope |> Reader.store(link, content, deadline: deadline) |> enrich() |> done()
    else
      {:error, reason} -> failed(scope, link, reason)
    end
  end

  # A link never enriched is worth enriching with the better text; one that
  # already was would gain little from a second paid call.
  defp enrich({:ok, %Link{content_html: html, enriched_at: nil, enrichment_status: status} = link})
       when is_binary(html) and status != :pending do
    case EnrichLink.enqueue(link) do
      {:ok, _job} -> {:ok, link}
      {:error, _reason} = error -> error
    end
  end

  defp enrich(result), do: result

  defp parse(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _part} -> {:error, :invalid_url}
    end
  end

  defp failed(scope, link, reason) do
    case CaptureLink.classify(reason) do
      :permanent ->
        Logger.info("no reader content for link #{link.id}: #{CaptureLink.error_code(reason)}")
        done(Reader.store(scope, link, :none))

      :transient ->
        {:error, reason}
    end
  end

  defp done({:ok, _link}), do: :ok
  defp done(:gone), do: :ok
  defp done({:error, _changeset} = error), do: error
end
