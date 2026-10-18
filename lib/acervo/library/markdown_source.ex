defmodule Acervo.Library.MarkdownSource do
  @moduledoc """
  Looks for a Markdown version of a page, which reads better than anything
  extracted from its HTML. In order:

    1. a `<link rel="alternate" type="text/markdown">` in the page;
    2. the page's URL with `.md`: `/foo` and `/foo.html` become `/foo.md`,
       `/docs/` and `/docs/index.html` become `/docs/index.md`;
    3. the site's `/llms.txt`, when it links to a `.md` for this page.

  Every request goes through `Acervo.Library.SafeFetch`, at most #{3} per
  page and #{1_000_000} bytes each. A response counts only when it is
  `text/markdown`, `text/x-markdown` or `text/plain`, doesn't look like HTML
  and holds at least #{200} characters. Anything else, errors included,
  moves on to the next candidate.
  """

  alias Acervo.Library.Reader
  alias Acervo.Library.SafeFetch
  alias Acervo.Library.Sanitizer

  @max_requests 3
  @max_bytes 1_000_000
  @min_chars 200
  @accept "text/markdown, text/x-markdown;q=0.9, text/plain;q=0.8"
  @markdown_types ~w(text/markdown text/x-markdown text/plain)
  @link_types ~w(text/markdown text/x-markdown)

  @type found :: %{markdown: String.t(), url: String.t()}

  @doc """
  Returns the Markdown for the page at `page_url`, parsed as `doc`, with the
  URL it came from, or `:none`. Takes the `:deadline` option of
  `Acervo.Library.Reader.build/3`.
  """
  @spec find(LazyHTML.t(), String.t(), keyword()) :: {:ok, found()} | :none
  def find(%LazyHTML{} = doc, page_url, opts \\ []) when is_binary(page_url) do
    case URI.new(page_url) do
      {:ok, %URI{scheme: scheme, host: host} = page} when scheme in ["http", "https"] and is_binary(host) ->
        steps = [&{alternate(doc, page_url), &1}, &{md_url(page), &1}, &from_llms_txt(page, &1)]
        try_steps(steps, %{budget: @max_requests, tried: MapSet.new(), deadline: Reader.deadline(opts)})

      _ ->
        :none
    end
  end

  defp try_steps([], _state), do: :none
  defp try_steps(_steps, %{budget: budget}) when budget <= 0, do: :none

  defp try_steps([step | rest], state) do
    if Reader.time_left?(state.deadline), do: try_step(step, rest, state), else: :none
  end

  defp try_step(step, rest, state) do
    case step.(state) do
      {url, state} when is_binary(url) -> attempt(url, rest, state)
      {nil, state} -> try_steps(rest, state)
    end
  end

  defp attempt(url, rest, state) do
    if MapSet.member?(state.tried, url) or state.budget <= 0 or not Reader.time_left?(state.deadline) do
      try_steps(rest, state)
    else
      state = %{state | budget: state.budget - 1, tried: MapSet.put(state.tried, url)}

      case fetch_markdown(url) do
        {:ok, found} -> {:ok, found}
        :error -> try_steps(rest, state)
      end
    end
  end

  ## Candidates

  defp alternate(doc, page_url) do
    doc
    |> LazyHTML.query("link[href][type]")
    |> Enum.find_value(fn link ->
      rel = link |> LazyHTML.attribute("rel") |> List.first("") |> String.downcase() |> String.split()
      type = link |> LazyHTML.attribute("type") |> List.first("") |> String.downcase() |> String.trim()

      if "alternate" in rel and type in @link_types,
        do: link |> LazyHTML.attribute("href") |> List.first() |> Sanitizer.safe_url(page_url)
    end)
  end

  @doc """
  The page's URL with `.md`, without its query or fragment.

      iex> Acervo.Library.MarkdownSource.md_url(URI.parse("https://example.com/docs/intro.html?x=1"))
      "https://example.com/docs/intro.md"

      iex> Acervo.Library.MarkdownSource.md_url(URI.parse("https://example.com/docs/"))
      "https://example.com/docs/index.md"
  """
  @spec md_url(URI.t()) :: String.t() | nil
  def md_url(%URI{path: path} = page) do
    path = path || "/"

    md_path =
      cond do
        String.ends_with?(path, ".md") -> nil
        String.ends_with?(path, "/") -> path <> "index.md"
        Regex.match?(~r/\.html?\z/i, path) -> Regex.replace(~r/\.html?\z/i, path, ".md")
        true -> path <> ".md"
      end

    if md_path, do: URI.to_string(%{page | path: md_path, query: nil, fragment: nil})
  end

  # Costs one request for llms.txt itself, then offers its link to this page.
  defp from_llms_txt(page, state) do
    llms_url = URI.to_string(%{page | path: "/llms.txt", query: nil, fragment: nil})

    if state.budget < 2 or MapSet.member?(state.tried, llms_url) or not Reader.time_left?(state.deadline) do
      {nil, state}
    else
      state = %{state | budget: state.budget - 1, tried: MapSet.put(state.tried, llms_url)}

      case fetch(llms_url, 1) do
        {:ok, body} -> {llms_match(body, llms_url, page), state}
        :error -> {nil, state}
      end
    end
  end

  @doc """
  Finds, among the Markdown links in an `llms.txt` body, a `.md` on the same
  host whose path, without `.md` or a trailing `/index`, is the page's path
  without `.html`, `/index.html` or a trailing slash.
  """
  @spec llms_match(String.t(), String.t(), URI.t()) :: String.t() | nil
  def llms_match(body, llms_url, %URI{host: host} = page) do
    wanted = page_key(page.path)

    ~r/\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.find_value(fn [href] ->
      with url when is_binary(url) <- Sanitizer.safe_url(href, llms_url),
           %URI{host: ^host, path: path} when is_binary(path) <- URI.parse(url),
           true <- String.ends_with?(path, ".md"),
           true <- md_key(path) == wanted do
        URI.to_string(%{URI.parse(url) | query: nil, fragment: nil})
      else
        _ -> nil
      end
    end)
  end

  defp page_key(nil), do: ""

  defp page_key(path) do
    path
    |> String.replace(~r/(\/index)?\.html?\z/i, "")
    |> String.trim_trailing("/")
  end

  defp md_key(path) do
    path
    |> String.replace_suffix(".md", "")
    |> String.replace(~r/\/index\z/, "")
    |> String.trim_trailing("/")
  end

  ## Fetching

  defp fetch_markdown(url) do
    case fetch(url, @min_chars) do
      {:ok, markdown} -> {:ok, %{markdown: markdown, url: url}}
      :error -> :error
    end
  end

  defp fetch(url, min_chars) do
    with {:ok, %{body: body} = response} when is_binary(body) <-
           SafeFetch.get(url, accept: @accept, max_bytes: @max_bytes),
         true <- markdown_type?(response),
         body = String.replace_invalid(body),
         false <- looks_like_html?(body),
         true <- String.length(String.trim(body)) >= min_chars do
      {:ok, body}
    else
      _ -> :error
    end
  end

  defp markdown_type?(%{headers: headers}) do
    headers
    |> Map.get("content-type", [])
    |> List.wrap()
    |> Enum.any?(fn value ->
      value |> String.split(";") |> hd() |> String.trim() |> String.downcase() |> Kernel.in(@markdown_types)
    end)
  end

  defp looks_like_html?(body) do
    start = body |> String.trim_leading("﻿") |> String.trim_leading() |> String.slice(0, 64) |> String.downcase()
    Enum.any?(["<!doctype", "<html", "<head", "<body", "<?xml"], &String.starts_with?(start, &1))
  end
end
