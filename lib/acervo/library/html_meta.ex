defmodule Acervo.Library.HtmlMeta do
  @moduledoc """
  Parses Open Graph, Twitter and standard meta tags plus the main text of an
  HTML document into an `Acervo.Library.Capture`.
  """

  alias Acervo.Library.Capture

  @max_images 4
  @max_text 8000
  @min_text 200
  @skipped_tags ~w(script style nav header footer aside noscript template)
  @block_tags ~w(p div br li h1 h2 h3 h4 h5 h6 blockquote section article tr)
  @latin1 ~w(iso-8859-1 latin1 latin-1 iso8859-1 windows-1252 cp1252 us-ascii ascii)

  @doc """
  Parses `html`. `content_type` is the response `content-type` header, used to
  find the charset; the result never contains invalid UTF-8.
  """
  @spec parse(binary(), String.t(), String.t() | nil) :: Capture.t()
  def parse(html, base_url, content_type \\ nil) when is_binary(html) and is_binary(base_url) do
    html |> document(content_type) |> parse_document(base_url)
  end

  @doc """
  Parses `html` into a `LazyHTML` document, decoding it by the charset in
  `content_type` or its `<meta charset>`.
  """
  @spec document(binary(), String.t() | nil) :: LazyHTML.t()
  def document(html, content_type \\ nil) when is_binary(html) do
    html |> decode(content_type) |> LazyHTML.from_document()
  end

  @doc "Like `parse/3`, for a document already parsed by `document/2`."
  @spec parse_document(LazyHTML.t(), String.t()) :: Capture.t()
  def parse_document(%LazyHTML{} = doc, base_url) when is_binary(base_url) do
    scrub(%Capture{
      title: first_meta(doc, [{"property", "og:title"}, {"name", "twitter:title"}]) || title_tag(doc),
      description:
        first_meta(doc, [{"property", "og:description"}, {"name", "twitter:description"}, {"name", "description"}]),
      site_name: first_meta(doc, [{"property", "og:site_name"}]),
      author: first_meta(doc, [{"name", "author"}, {"property", "article:author"}]),
      published_at: published_at(first_meta(doc, [{"property", "article:published_time"}])),
      image_urls: image_urls(doc, base_url),
      text: main_text(doc),
      canonical_url: doc |> attr("link[rel=canonical]", "href") |> List.first() |> blank_to_nil() |> absolutize(base_url)
    })
  end

  @doc """
  Plain text of a `LazyHTML` value, with block tags and `<br>` as separators.
  """
  @spec plain_text(LazyHTML.t()) :: String.t()
  def plain_text(lazy), do: lazy |> LazyHTML.to_tree() |> Enum.flat_map(&collect_text/1) |> Enum.join() |> collapse()

  defp decode(html, content_type) do
    charset = header_charset(content_type) || meta_charset(html)

    if charset in @latin1 do
      case :unicode.characters_to_binary(html, :latin1) do
        decoded when is_binary(decoded) -> decoded
        _ -> html
      end
    else
      html
    end
  end

  defp header_charset(nil), do: nil

  defp header_charset(content_type) do
    case Regex.run(~r/charset\s*=\s*"?([\w.:-]+)/i, content_type) do
      [_, charset] -> String.downcase(charset)
      _ -> nil
    end
  end

  defp meta_charset(html) do
    case Regex.run(~r/<meta[^>]+charset\s*=\s*["']?([\w.:-]+)/i, binary_part(html, 0, min(byte_size(html), 2048))) do
      [_, charset] -> String.downcase(charset)
      _ -> nil
    end
  end

  defp scrub(%Capture{} = capture) do
    Enum.reduce([:title, :description, :author, :site_name, :text, :canonical_url], capture, fn field, acc ->
      case Map.get(acc, field) do
        value when is_binary(value) -> Map.put(acc, field, String.replace_invalid(value))
        _ -> acc
      end
    end)
  end

  defp first_meta(doc, selectors) do
    Enum.find_value(selectors, fn {key, value} ->
      doc |> metas(key, value) |> List.first()
    end)
  end

  defp metas(doc, key, value) do
    doc |> attr(~s(meta[#{key}="#{value}"]), "content") |> clean_all()
  end

  defp attr(doc, selector, name), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  defp title_tag(doc) do
    doc |> LazyHTML.query("title") |> LazyHTML.text() |> blank_to_nil() |> collapse()
  end

  defp published_at(nil), do: nil

  defp published_at(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> nil
    end
  end

  defp image_urls(doc, base_url) do
    ["og:image", "og:image:secure_url"]
    |> Enum.flat_map(&metas(doc, "property", &1))
    |> Enum.concat(metas(doc, "name", "twitter:image"))
    |> Enum.map(&absolutize(&1, base_url))
    |> Enum.filter(&http_url?/1)
    |> Enum.uniq()
    |> Enum.take(@max_images)
  end

  defp http_url?(nil), do: false

  defp http_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp main_text(doc) do
    best = doc |> candidate_texts(["article", "main", "[role=main]"]) |> longest()

    chosen =
      if is_nil(best) or String.length(best) < @min_text do
        body = doc |> candidate_texts(["body"]) |> longest()
        longest([best, body])
      else
        best
      end

    truncate(chosen)
  end

  defp candidate_texts(doc, selectors) do
    selectors
    |> Enum.flat_map(fn selector -> doc |> LazyHTML.query(selector) |> LazyHTML.to_tree() end)
    |> Enum.map(&(&1 |> collect_text() |> Enum.join() |> collapse() |> blank_to_nil()))
    |> Enum.reject(&is_nil/1)
  end

  defp longest(texts), do: Enum.max_by(Enum.reject(texts, &is_nil/1), &String.length/1, fn -> nil end)

  defp collect_text(nil), do: []
  defp collect_text(text) when is_binary(text), do: [text]
  defp collect_text({:comment, _}), do: []
  defp collect_text({tag, _attrs, _children}) when tag in @skipped_tags, do: []

  defp collect_text({tag, _attrs, children}) when tag in @block_tags,
    do: [" " | Enum.flat_map(children, &collect_text/1)] ++ [" "]

  defp collect_text({_tag, _attrs, children}), do: Enum.flat_map(children, &collect_text/1)

  defp truncate(nil), do: nil
  defp truncate(text), do: text |> String.slice(0, @max_text) |> String.trim_trailing()

  defp collapse(nil), do: nil
  defp collapse(text), do: text |> String.split() |> Enum.join(" ")

  defp clean_all(values), do: values |> Enum.map(&(&1 |> collapse() |> blank_to_nil())) |> Enum.reject(&is_nil/1)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp absolutize(nil, _base), do: nil

  defp absolutize(url, base) do
    case URI.new(url) do
      {:ok, relative} -> base |> URI.merge(relative) |> URI.to_string()
      {:error, _} -> nil
    end
  rescue
    ArgumentError -> nil
  end
end
