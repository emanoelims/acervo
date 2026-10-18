defmodule Acervo.Library.Embed do
  @moduledoc """
  What the web view column frames for a link.

  YouTube videos, X posts and Instagram posts use their official embed pages,
  which always allow framing. Any other page is framed at its own URL, but
  only over `https` and once its capture found it embeddable (see
  `Acervo.Library.FramePolicy`).
  """

  alias Acervo.Library.Link

  @youtube_hosts ~w(youtube.com www.youtube.com m.youtube.com music.youtube.com)
  @x_hosts ~w(x.com www.x.com mobile.x.com twitter.com www.twitter.com mobile.twitter.com)
  @instagram_hosts ~w(instagram.com www.instagram.com)
  @instagram_kinds ~w(p reel reels tv)

  @id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @status_id ~r/\A\d{1,25}\z/

  @type frame ::
          {:embed, :video | :post, String.t()}
          | {:page, String.t()}
          | :unknown
          | :blocked

  @doc """
  Returns what to frame for `link`:

    * `{:embed, kind, url}` - an official embed page, `:video` or `:post`;
    * `{:page, url}` - the page itself;
    * `:unknown` - a page whose embeddability hasn't been checked yet;
    * `:blocked` - a page that can't be framed.
  """
  @spec frame(Link.t()) :: frame()
  def frame(%Link{} = link) do
    case embed_url(link.canonical_url) || embed_url(link.resolved_url) do
      {kind, url} -> {:embed, kind, url}
      nil -> page_frame(link)
    end
  end

  defp page_frame(%Link{embeddable: nil}), do: :unknown

  defp page_frame(%Link{embeddable: true} = link) do
    url = original_url(link)
    if URI.parse(url).scheme == "https", do: {:page, url}, else: :blocked
  end

  defp page_frame(%Link{embeddable: false}), do: :blocked

  @doc "Where the link lives now: the URL its capture resolved, else the saved one."
  @spec original_url(Link.t()) :: String.t()
  def original_url(%Link{resolved_url: resolved, canonical_url: canonical}), do: resolved || canonical

  @doc """
  Returns the official embed URL for a YouTube video, X post or Instagram
  post URL, with its kind, or `nil` for anything else.

      iex> Acervo.Library.Embed.embed_url("https://youtu.be/dQw4w9WgXcQ")
      {:video, "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"}
  """
  @spec embed_url(String.t() | nil) :: {:video | :post, String.t()} | nil
  def embed_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when scheme in ["http", "https"] and is_binary(host) ->
        uri |> Map.update!(:host, &String.downcase/1) |> embed_uri()

      _ ->
        nil
    end
  end

  def embed_url(nil), do: nil

  defp embed_uri(%URI{host: "youtu.be"} = uri), do: uri |> segments() |> List.first() |> youtube()

  defp embed_uri(%URI{host: host} = uri) when host in @youtube_hosts do
    case segments(uri) do
      ["watch" | _] -> youtube(query_param(uri, "v"))
      [kind, id | _] when kind in ~w(shorts embed live v) -> youtube(id)
      _ -> nil
    end
  end

  defp embed_uri(%URI{host: host} = uri) when host in @x_hosts do
    case segments(uri) do
      ["i", "web", "status", id | _] -> x_post(id)
      [_user, "status", id | _] -> x_post(id)
      _ -> nil
    end
  end

  defp embed_uri(%URI{host: host} = uri) when host in @instagram_hosts do
    case segments(uri) do
      [kind, code | _] when kind in @instagram_kinds -> instagram(code)
      [_user, kind, code | _] when kind in @instagram_kinds -> instagram(code)
      _ -> nil
    end
  end

  defp embed_uri(%URI{}), do: nil

  defp youtube(id) when is_binary(id) do
    if Regex.match?(@id, id), do: {:video, "https://www.youtube-nocookie.com/embed/#{id}"}
  end

  defp youtube(nil), do: nil

  defp x_post(id) do
    if Regex.match?(@status_id, id), do: {:post, "https://platform.twitter.com/embed/Tweet.html?id=#{id}&dnt=true"}
  end

  defp instagram(code) do
    if Regex.match?(@id, code), do: {:post, "https://www.instagram.com/p/#{code}/embed"}
  end

  defp segments(%URI{path: path}), do: String.split(path || "", "/", trim: true)

  defp query_param(%URI{query: nil}, _key), do: nil

  defp query_param(%URI{query: query}, key) do
    query |> URI.decode_query() |> Map.get(key)
  rescue
    # A malformed escape in someone else's query string.
    ArgumentError -> nil
  end
end
