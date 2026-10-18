defmodule Acervo.Library.Extractors.Generic do
  @moduledoc """
  Fallback extractor: fetches the page and parses its meta tags and text.
  """
  @behaviour Acervo.Library.Extractor

  alias Acervo.Library.Capture
  alias Acervo.Library.HtmlMeta
  alias Acervo.Library.SafeFetch

  @accept "text/html,application/xhtml+xml"

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
  Like `fetch/2`, but also returns the final URL after redirects.
  """
  @spec fetch_page(URI.t(), keyword()) :: {:ok, Capture.t(), String.t()} | {:error, term()}
  def fetch_page(%URI{} = uri, opts) do
    case SafeFetch.get(URI.to_string(uri), Keyword.put(opts, :accept, @accept)) do
      {:ok, %{body: body, url: url} = response} when is_binary(body) ->
        if html?(response), do: {:ok, HtmlMeta.parse(body, url), url}, else: {:error, :not_html}

      {:ok, _response} ->
        {:error, :not_html}

      {:error, {:http, status}} when status in [404, 410] ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp html?(%{headers: headers}) do
    headers
    |> Map.get("content-type", [])
    |> List.wrap()
    |> Enum.any?(&(String.contains?(&1, "html") or String.contains?(&1, "xml")))
  end
end
