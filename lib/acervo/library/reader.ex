defmodule Acervo.Library.Reader do
  @moduledoc """
  Builds and stores a link's reader view: its article as sanitized HTML,
  with its images served from Acervo.

  The article comes from the page's Markdown when `Acervo.Library.MarkdownSource`
  finds one, else from its HTML (`Acervo.Library.Article`). Both go through
  `Acervo.Library.Sanitizer`.

  Inline images, at most #{20}, are downloaded one at a time through
  `Acervo.Library.SafeFetch`, normalized by `Acervo.Library.Images` and stored
  as link images of kind `:content`. Each `src` then points at `/images/:id`
  with the stored size; an image that fails is left out. Storing replaces the
  link's previous content and content images, so it can run again safely. It
  never touches anything else on the link.
  """

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.Library.Article
  alias Acervo.Library.Images
  alias Acervo.Library.Link
  alias Acervo.Library.LinkImage
  alias Acervo.Library.MarkdownSource
  alias Acervo.Library.SafeFetch
  alias Acervo.Repo
  alias Acervo.Storage

  require Logger

  @max_image_bytes 15_000_000
  @min_side 16
  # A request may take up to SafeFetch's 30 s request timeout; none starts
  # unless it can finish before the deadline.
  @request_ms 30_000

  @type content :: %{html: String.t(), images: [String.t()], source: :markdown | :html}

  @doc """
  Builds the reader content for the page at `page_url`, parsed as `doc`.

  ## Options

    * `:deadline` - monotonic time in milliseconds after which no request
      starts; defaults to two minutes from now
  """
  @spec build(LazyHTML.t(), String.t(), keyword()) :: {:ok, content()} | :none
  def build(%LazyHTML{} = doc, page_url, opts \\ []) do
    deadline = deadline(opts)

    with :none <- from_markdown(doc, page_url, deadline),
         {:ok, content} <- Article.extract(doc, page_url) do
      {:ok, Map.put(content, :source, :html)}
    end
  end

  defp from_markdown(doc, page_url, deadline) do
    with {:ok, %{markdown: markdown, url: url}} <- MarkdownSource.find(doc, page_url, deadline: deadline),
         {:ok, content} <- Article.from_markdown(markdown, url) do
      {:ok, Map.put(content, :source, :markdown)}
    end
  end

  @doc """
  Stores `content` (or, for `:none`, the absence of any) as the link's reader
  view, downloading its images first. Returns the updated link, or `:gone`
  when the link was deleted meanwhile.

  Takes the same `:deadline` option as `build/3`.
  """
  @spec store(Scope.t(), Link.t(), {:ok, content()} | :none, keyword()) ::
          {:ok, Link.t()} | :gone | {:error, Ecto.Changeset.t()}
  def store(scope, link, content, opts \\ [])

  def store(%Scope{} = _scope, %Link{} = link, :none, _opts) do
    save(link, [], %{content_html: nil, content_source: nil})
  end

  def store(%Scope{} = scope, %Link{} = link, {:ok, %{html: html, images: urls, source: source}}, opts) do
    stored = store_images(scope, link, urls, deadline(opts))

    html =
      Article.replace_images(html, link.canonical_url, fn url ->
        case Map.fetch(stored, url) do
          {:ok, image} -> {:ok, %{src: "/images/#{image.id}", width: image.width, height: image.height}}
          :error -> :drop
        end
      end)

    ids = stored |> Map.values() |> Enum.map(& &1.id) |> Enum.uniq()
    save(link, ids, %{content_html: html, content_source: source})
  end

  # Replaces the content and drops the content images it no longer uses, at once.
  defp save(link, keep_ids, attrs) do
    attrs = Map.put(attrs, :content_extracted_at, DateTime.utc_now(:second))

    fn ->
      Repo.delete_all(from i in LinkImage, where: i.link_id == ^link.id and i.kind == :content and i.id not in ^keep_ids)

      case link |> Link.content_changeset(attrs) |> Repo.update(stale_error_field: :id) do
        {:ok, link} -> {:ok, link}
        {:error, %Ecto.Changeset{errors: [id: {"is stale", _}]}} -> {:error, :gone}
        {:error, changeset} -> {:error, changeset}
      end
    end
    |> Repo.transact()
    |> case do
      {:error, :gone} -> :gone
      result -> result
    end
  end

  ## Images

  # One image at a time, keeping only each stored image's id and size.
  defp store_images(scope, link, urls, deadline) do
    {stored, _by_hash} =
      urls
      |> Enum.with_index()
      |> Enum.reduce_while({%{}, %{}}, fn {url, position}, {stored, by_hash} ->
        if time_left?(deadline) do
          {:cont, store_image(scope, link, url, position, stored, by_hash)}
        else
          {:halt, {stored, by_hash}}
        end
      end)

    stored
  end

  defp store_image(scope, link, url, position, stored, by_hash) do
    with {:ok, %{body: body}} <- SafeFetch.get(url, max_bytes: @max_image_bytes, accept: "image/*"),
         {:ok, image} <- Images.normalize(body),
         :ok <- big_enough(image),
         {:ok, entry} <- reuse_or_put(scope, link, image, position, by_hash) do
      {Map.put(stored, url, entry), Map.put(by_hash, image.sha256, entry)}
    else
      skipped ->
        Logger.debug("skipped content image #{url}: #{inspect(skipped)}")
        {stored, by_hash}
    end
  end

  # The same image under another URL is stored once.
  defp reuse_or_put(scope, link, image, position, by_hash) do
    case Map.fetch(by_hash, image.sha256) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        with {:ok, saved} <- Storage.put(scope, link, Map.merge(image, %{kind: :content, position: position})) do
          {:ok, %{id: saved.id, width: saved.width, height: saved.height}}
        end
    end
  end

  # Tracking pixels and spacers.
  defp big_enough(%{width: w, height: h}) when w >= @min_side and h >= @min_side, do: :ok
  defp big_enough(_image), do: :too_small

  ## Time

  @doc false
  @spec deadline(keyword()) :: integer()
  def deadline(opts), do: Keyword.get_lazy(opts, :deadline, fn -> System.monotonic_time(:millisecond) + 120_000 end)

  @doc false
  @spec time_left?(integer()) :: boolean()
  def time_left?(deadline), do: System.monotonic_time(:millisecond) + @request_ms <= deadline
end
