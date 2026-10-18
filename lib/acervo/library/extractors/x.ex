defmodule Acervo.Library.Extractors.X do
  @moduledoc """
  Extracts a post from X through the publish oEmbed endpoint. The page itself
  is fetched on a best-effort basis, only to find images.
  """
  @behaviour Acervo.Library.Extractor

  alias Acervo.Library.Capture
  alias Acervo.Library.Extractors.Generic
  alias Acervo.Library.HtmlMeta
  alias Acervo.Library.SafeFetch

  @hosts ["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"]

  @impl true
  def match?(%URI{host: host}), do: host in @hosts

  @impl true
  def extract(%URI{} = uri) do
    with {:ok, data} <- oembed(uri) do
      author = data["author_name"]

      {:ok,
       %Capture{
         title: author && "#{author} on X",
         author: author,
         site_name: "X",
         text: tweet_text(data["html"]),
         image_urls: image_urls(uri)
       }}
    end
  end

  defp oembed(uri) do
    url = "https://publish.twitter.com/oembed?url=#{URI.encode_www_form(URI.to_string(uri))}&omit_script=true"

    case SafeFetch.get(url) do
      {:ok, %{body: body}} -> decode(body)
      {:error, {:http, 404}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = data} -> {:ok, data}
      _ -> {:error, :invalid_response}
    end
  end

  defp tweet_text(html) when is_binary(html) do
    text = html |> LazyHTML.from_fragment() |> LazyHTML.query("blockquote p") |> HtmlMeta.plain_text()

    case text do
      "" -> nil
      text -> text
    end
  end

  defp tweet_text(_), do: nil

  # X often blocks scrapers, so any failure just means no images.
  defp image_urls(uri) do
    case Generic.fetch(uri, []) do
      {:ok, %Capture{image_urls: urls}} -> urls
      {:error, _} -> []
    end
  end
end
