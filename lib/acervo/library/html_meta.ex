defmodule Acervo.Library.HtmlMeta do
  @moduledoc """
  Parses Open Graph, Twitter and standard meta tags plus the main text of an
  HTML document into an `Acervo.Library.Capture`.
  """

  alias Acervo.Library.Capture

  @max_images 4
  @max_text 8000
  @skipped_tags ~w(script style nav header footer aside noscript template)

  @spec parse(binary(), String.t()) :: Capture.t()
  def parse(html, base_url) when is_binary(html) and is_binary(base_url) do
    doc = LazyHTML.from_document(html)

    %Capture{
      title: first_meta(doc, [{"property", "og:title"}, {"name", "twitter:title"}]) || title_tag(doc),
      description:
        first_meta(doc, [{"property", "og:description"}, {"name", "twitter:description"}, {"name", "description"}]),
      site_name: first_meta(doc, [{"property", "og:site_name"}]),
      author: first_meta(doc, [{"name", "author"}, {"property", "article:author"}]),
      published_at: published_at(first_meta(doc, [{"property", "article:published_time"}])),
      image_urls: image_urls(doc, base_url),
      text: main_text(doc),
      canonical_url: doc |> attr("link[rel=canonical]", "href") |> List.first() |> blank_to_nil() |> absolutize(base_url)
    }
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
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@max_images)
  end

  defp main_text(doc) do
    node =
      Enum.find_value(["article", "main", "body"], fn selector ->
        doc |> LazyHTML.query(selector) |> LazyHTML.to_tree() |> List.first()
      end)

    node
    |> collect_text()
    |> Enum.join(" ")
    |> collapse()
    |> blank_to_nil()
    |> truncate()
  end

  defp collect_text(nil), do: []
  defp collect_text(text) when is_binary(text), do: [text]
  defp collect_text({:comment, _}), do: []
  defp collect_text({tag, _attrs, _children}) when tag in @skipped_tags, do: []
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
