defmodule Acervo.Library.CaptureLink do
  @moduledoc """
  Captures a saved link's preview: runs `Acervo.Library.Extractor`, stores up
  to four preview images normalized to WebP, and fills the link's fields.
  The link's `canonical_url` (its dedupe key) never changes: the page's own
  canonical URL, or else its final URL after redirects, goes to `resolved_url`.

  Errors that will not change on retry (blocked, not found, not HTML, an
  address or port SafeFetch refuses, an invalid URL, a redirect loop or any
  4xx) leave the link `:ready` with a `capture_error` and do not retry.
  Anything else (timeouts, transport errors, 5xx, an oversized body or an
  unexpected response) puts the link back to `:pending` and retries, ending
  `:failed` on the last attempt. An exception during the capture is logged
  and handled as a transient error coded `"crashed"`. Every run broadcasts
  `{:link_updated, link}`.

  Generic pages also get their reader view (`Acervo.Library.Reader`) once the
  preview is saved; YouTube, X and Instagram keep their embeds instead. A
  failure there is logged and never fails the capture.

  A first capture enqueues `Acervo.AI.EnrichLink`, which embeds the link for
  search once it finishes. A re-capture of an enriched link, and a capture
  that ends with a permanent error, enqueue `Acervo.Search.EmbedLink`
  directly.

  A run never leaves the link `:processing` on its own. A job killed mid-run
  (by its timeout or a node restart rescued by `Oban.Plugins.Lifeline`) is
  retried, and every run starts over whatever the link's status. When the
  killed run was the last attempt, `Acervo.Library.ReapStuckCaptures` marks
  the link `:failed`.
  """
  use Oban.Worker, queue: :capture, max_attempts: 5, unique: [period: 60, keys: [:link_id]]

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.AI.EnrichLink
  alias Acervo.Library
  alias Acervo.Library.Capture
  alias Acervo.Library.Extractor
  alias Acervo.Library.Images
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage
  alias Acervo.Library.Reader
  alias Acervo.Library.SafeFetch
  alias Acervo.Library.URL
  alias Acervo.Repo
  alias Acervo.Search.EmbedLink
  alias Acervo.Storage

  require Logger

  @max_images 4
  # The reader view starts no request after this, well within the timeout.
  @content_ms 150_000
  @max_image_bytes 15_000_000
  @permanent_errors [:blocked, :not_found, :not_html, :blocked_address, :bad_port, :invalid_url, :too_many_redirects]

  @impl Oban.Worker
  def timeout(_job), do: to_timeout(minute: 3)

  # No status check here: a link left `:processing` by a killed run is
  # captured again, like any retry.
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"link_id" => link_id}, attempt: attempt, max_attempts: max_attempts} = job) do
    deadline = System.monotonic_time(:millisecond) + @content_ms
    run = %{final_attempt?: attempt >= max_attempts, deadline: deadline, priority: job.priority || 0}

    case load(link_id) do
      {:ok, scope, link} ->
        result = capture(scope, link, run)
        Library.broadcast_updated(scope, link.id)
        result

      :error ->
        :ok
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

  # Extracts from the canonical URL, which always has an http(s) scheme even
  # when the user typed a bare host.
  defp capture(scope, link, run) do
    case update_link(link, %{status: :processing}) do
      {:ok, link} -> safely_extract(scope, link, run)
      gone_or_error -> finish(gone_or_error, :ok)
    end
  end

  defp safely_extract(scope, link, run) do
    extract(scope, link, run)
  rescue
    exception ->
      log_crash(link, exception, __STACKTRACE__)
      handle_error(link, :crashed, run.final_attempt?)
  end

  # Logs the exception's type and stacktrace only: its message and the call
  # arguments could carry page content.
  defp log_crash(link, exception, stacktrace, what \\ "capture") do
    stacktrace =
      Enum.map(stacktrace, fn
        {module, fun, args, location} when is_list(args) -> {module, fun, length(args), location}
        entry -> entry
      end)

    Logger.error(
      "#{what} of link #{link.id} crashed with #{inspect(exception.__struct__)}\n" <>
        Exception.format_stacktrace(stacktrace)
    )
  end

  defp extract(scope, link, run) do
    case Extractor.extract(link.canonical_url) do
      {:ok, %Capture{} = capture} -> apply_capture(scope, link, capture, run)
      {:error, reason} -> handle_error(link, reason, run.final_attempt?)
    end
  end

  ## Success

  defp apply_capture(scope, link, %Capture{} = capture, run) do
    store_images(scope, link, capture.image_urls)

    # A page without a title keeps the one the link came with (an imported
    # bookmark's).
    attrs = %{
      title: capture.title || link.title,
      description: capture.description,
      author: capture.author,
      site_name: capture.site_name,
      published_at: capture.published_at,
      text_excerpt: capture.text,
      embeddable: capture.embeddable,
      status: :ready,
      capture_error: nil
    }

    link
    |> Link.capture_changeset(Map.merge(attrs, resolved_url(capture)))
    |> save()
    |> tap(&store_content(scope, &1, capture, run))
    |> tap(&enrich(&1, run.priority))
    |> finish(:ok)
  end

  ## Enrichment

  # Once per link: a re-capture, or a retry after the link was saved, does
  # not pay for the model again. A screenshot enqueues it on its own.
  # Enrichment embeds the link when it finishes; without it, embed now. It
  # runs at the capture's priority, so imported links stay behind others.
  defp enrich({:ok, %Link{enriched_at: nil} = link}, priority) do
    case EnrichLink.enqueue(link, priority: priority) do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.error("could not enqueue enrichment of link #{link.id}: #{inspect(reason)}")
    end
  end

  defp enrich(saved, _priority), do: embed(saved)

  # Nothing changed costs nothing: `EmbedLink` skips an unchanged document.
  defp embed({:ok, %Link{} = link}) do
    case EmbedLink.enqueue(link) do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.error("could not enqueue embedding of link #{link.id}: #{inspect(reason)}")
    end
  end

  defp embed(_gone_or_error), do: :ok

  ## Reader view

  defp store_content(scope, {:ok, %Link{source: :generic} = link}, %Capture{document: %LazyHTML{} = doc} = capture, run) do
    page_url = capture.final_url || link.canonical_url
    content = Reader.build(doc, page_url, deadline: run.deadline)
    Reader.store(scope, link, content, deadline: run.deadline)
  rescue
    exception -> log_crash(link, exception, __STACKTRACE__, "reader content")
  end

  defp store_content(_scope, _saved, _capture, _run), do: :ok

  # `canonical_url` is the immutable dedupe key and never changes. Where the
  # page says it lives (its canonical URL, or else where the fetch ended up
  # after redirects) goes to `resolved_url`, which `Library.save_link/2` also
  # matches and "open original" prefers.
  defp resolved_url(%Capture{canonical_url: canonical, final_url: final}) do
    case Enum.find_value([canonical, final], &valid_url/1) do
      nil -> %{}
      url -> %{resolved_url: url}
    end
  end

  defp valid_url(url) when is_binary(url) do
    case URL.normalize(url) do
      {:ok, normalized} when byte_size(normalized) <= 2048 -> normalized
      _ -> nil
    end
  end

  defp valid_url(nil), do: nil

  ## Images

  # Previews already stored (say, by an earlier attempt) count towards the
  # limit and are recognized by their hash, so a re-capture adds no duplicates.
  defp store_images(scope, link, urls) do
    existing =
      Repo.all(
        from i in LinkImage,
          where: i.link_id == ^link.id and i.kind != :content,
          select: %{sha256: i.sha256, kind: i.kind, position: i.position}
      )

    state = %{
      hashes: MapSet.new(existing, & &1.sha256),
      stored: Enum.count(existing, &(&1.kind == :preview)),
      position: existing |> Enum.map(& &1.position) |> Enum.max(fn -> -1 end) |> Kernel.+(1)
    }

    Enum.reduce_while(urls, state, fn
      _url, %{stored: stored} = state when stored >= @max_images -> {:halt, state}
      url, state -> {:cont, store_image(scope, link, url, state)}
    end)
  end

  defp store_image(scope, link, url, state) do
    with {:ok, %{body: body}} <- SafeFetch.get(url, max_bytes: @max_image_bytes, accept: "image/*"),
         {:ok, image} <- Images.normalize(body),
         :new <- if(MapSet.member?(state.hashes, image.sha256), do: :duplicate, else: :new),
         {:ok, _image} <- Storage.put(scope, link, Map.merge(image, %{kind: :preview, position: state.position})) do
      %{
        state
        | hashes: MapSet.put(state.hashes, image.sha256),
          stored: state.stored + 1,
          position: state.position + 1
      }
    else
      skipped ->
        Logger.debug("skipped preview image #{url}: #{inspect(skipped)}")
        state
    end
  end

  ## Errors

  defp handle_error(link, reason, final_attempt?) do
    case {classify(reason), final_attempt?} do
      {:permanent, _} ->
        link
        |> update_link(%{status: :ready, capture_error: error_code(reason)})
        |> tap(&embed/1)
        |> finish(:ok)

      {:transient, false} ->
        link |> update_link(%{status: :pending, capture_error: nil}) |> finish({:error, reason})

      {:transient, true} ->
        link |> update_link(%{status: :failed, capture_error: error_code(reason)}) |> finish({:error, reason})
    end
  end

  @doc false
  @spec classify(term()) :: :permanent | :transient
  def classify(reason) when reason in @permanent_errors, do: :permanent
  def classify({:http, status}) when status in 400..499, do: :permanent
  def classify(_reason), do: :transient

  @doc false
  @spec error_code(term()) :: String.t()
  def error_code({:http, status}) when is_integer(status), do: "http_#{status}"
  def error_code({:transport, reason}) when is_atom(reason), do: "transport_#{reason}"
  def error_code({:transport, _reason}), do: "transport"
  def error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  def error_code(_reason), do: "unknown"

  ## Persistence

  defp update_link(link, attrs), do: link |> Link.capture_changeset(attrs) |> save()

  defp finish({:ok, %Link{}}, result), do: result
  defp finish(:gone, _result), do: :ok
  defp finish({:error, _changeset} = error, _result), do: error

  # A link deleted mid-capture makes the update stale: there is nothing left
  # to capture, so the job ends quietly.
  defp save(changeset) do
    case Repo.update(changeset, stale_error_field: :id) do
      {:ok, link} -> {:ok, link}
      {:error, %Ecto.Changeset{errors: [id: {"is stale", _}]}} -> :gone
      {:error, changeset} -> {:error, changeset}
    end
  end
end
