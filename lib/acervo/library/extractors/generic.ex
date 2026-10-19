defmodule Acervo.Library.Extractors.Generic do
  @moduledoc """
  Fallback extractor: fetches the page and parses its meta tags and text.
  """
  @behaviour Acervo.Library.Extractor

  alias Acervo.Library.Capture
  alias Acervo.Library.FramePolicy
  alias Acervo.Library.HtmlMeta
  alias Acervo.Library.SafeFetch

  @accept "text/html,application/xhtml+xml"
  @max_meta_refreshes 2
  @max_refresh_delay 5

  @impl true
  def match?(%URI{}), do: true

  @impl true
  def extract(%URI{} = uri), do: fetch(uri, [])

  @doc """
  Extracts `uri`, passing `opts` (such as `:user_agent`) to `SafeFetch.get/2`.
  """
  @spec fetch(URI.t(), keyword()) :: {:ok, Capture.t()} | {:error, term()}
  def fetch(%URI{} = uri, opts) do
    with {:ok, capture, _final_url} <- fetch_page(uri, opts), do: {:ok, capture}
  end

  @doc """
  Like `fetch/2`, but also returns the final URL after redirects, which the
  capture carries as `final_url` too. The capture's `embeddable` follows the
  final response's headers, and its `document` is the parsed page.
  """
  @spec fetch_page(URI.t(), keyword()) :: {:ok, Capture.t(), String.t()} | {:error, term()}
  def fetch_page(%URI{} = uri, opts), do: fetch_page(uri, opts, @max_meta_refreshes)

  defp fetch_page(uri, opts, refreshes_left) do
    case SafeFetch.get(URI.to_string(uri), Keyword.put(opts, :accept, @accept)) do
      {:ok, %{body: body, url: url} = response} when is_binary(body) ->
        if html?(response),
          do: build(body, response, url, opts, refreshes_left),
          else: {:error, :not_html}

      {:ok, _response} ->
        {:error, :not_html}

      {:error, {:http, status}} when status in [404, 410] ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build(body, response, url, opts, refreshes_left) do
    capture = %{parse(body, response) | final_url: url, embeddable: FramePolicy.embeddable?(url, response.headers)}

    # A page that redirects with `<meta http-equiv="refresh">` is a stub: follow
    # it, through SafeFetch again, up to `@max_meta_refreshes` times. Past that
    # the last page is used as it is.
    with true <- refreshes_left > 0,
         {:ok, target} <- meta_refresh(capture.document, url),
         {:ok, _, _} = followed <- fetch_page(target, opts, refreshes_left - 1) do
      followed
    else
      _ -> {:ok, capture, url}
    end
  end

  @doc false
  # The URL a page's `<meta http-equiv="refresh">` sends the browser to, when it
  # does so within `@max_refresh_delay` seconds, to a different http(s) URL.
  @spec meta_refresh(LazyHTML.t(), String.t()) :: {:ok, URI.t()} | :error
  def meta_refresh(doc, page_url) do
    doc
    |> LazyHTML.query(~s(meta[http-equiv="refresh" i]))
    |> LazyHTML.attribute("content")
    |> Enum.find_value(:error, fn content ->
      case parse_refresh(content, page_url) do
        {:ok, _} = found -> found
        :error -> nil
      end
    end)
  end

  defp parse_refresh(content, page_url) do
    with [_, delay, rest] <- Regex.run(~r/^\s*(\d+(?:\.\d*)?)\s*[;,]?\s*(.*)$/s, content),
         true <- elem(Float.parse(delay), 0) <= @max_refresh_delay,
         [_, target] <- Regex.run(~r/^url\s*=\s*(.*)$/is, String.trim(rest)),
         target = target |> String.trim() |> String.trim("\"") |> String.trim("'") |> String.trim(),
         true <- target != "",
         {:ok, relative} <- URI.new(target),
         %URI{scheme: scheme, host: host} = next when scheme in ["http", "https"] and is_binary(host) <-
           URI.merge(URI.parse(page_url), relative),
         true <- strip_fragment(next) != strip_fragment(URI.parse(page_url)) do
      {:ok, next}
    else
      _ -> :error
    end
  end

  defp strip_fragment(%URI{} = uri), do: %{uri | fragment: nil}

  defp parse(body, response) do
    doc = HtmlMeta.document(body, content_type(response))
    %{HtmlMeta.parse_document(doc, response.url) | document: doc}
  end

  defp content_types(%{headers: headers}), do: headers |> Map.get("content-type", []) |> List.wrap()

  defp content_type(response), do: response |> content_types() |> List.first()

  defp html?(response) do
    response
    |> content_types()
    |> Enum.any?(&(String.contains?(&1, "html") or String.contains?(&1, "xml")))
  end
end
