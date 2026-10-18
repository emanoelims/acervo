defmodule Acervo.Library.Extractors.YouTube do
  @moduledoc """
  Extracts a YouTube video preview through the public oEmbed endpoint.
  """
  @behaviour Acervo.Library.Extractor

  alias Acervo.Library.Capture
  alias Acervo.Library.SafeFetch

  @hosts ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"]

  @impl true
  def match?(%URI{host: host}), do: host in @hosts

  @impl true
  def extract(%URI{} = uri) do
    with {:ok, id} <- video_id(uri),
         {:ok, data} <- oembed(uri) do
      {:ok,
       %Capture{
         title: data["title"],
         author: data["author_name"],
         site_name: data["provider_name"],
         image_urls: [
           "https://i.ytimg.com/vi/#{id}/maxresdefault.jpg",
           "https://i.ytimg.com/vi/#{id}/hqdefault.jpg"
         ]
       }}
    end
  end

  defp video_id(%URI{host: "youtu.be", path: "/" <> id}) when id != "", do: {:ok, hd(String.split(id, "/"))}
  defp video_id(%URI{path: "/shorts/" <> id}) when id != "", do: {:ok, hd(String.split(id, "/"))}

  defp video_id(%URI{query: query}) when is_binary(query) do
    case query |> URI.decode_query() |> Map.get("v") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :invalid_url}
    end
  end

  defp video_id(%URI{}), do: {:error, :invalid_url}

  defp oembed(uri) do
    url = "https://www.youtube.com/oembed?url=#{URI.encode_www_form(URI.to_string(uri))}&format=json"

    case SafeFetch.get(url) do
      {:ok, %{body: body}} -> decode(body)
      {:error, {:http, status}} when status in [404, 401] -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = data} -> {:ok, data}
      _ -> {:error, :invalid_response}
    end
  end
end
