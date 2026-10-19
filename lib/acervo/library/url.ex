defmodule Acervo.Library.URL do
  @moduledoc """
  Normalizes saved link URLs into a canonical form and detects their source.

  The canonical form is what the capture pipeline uses to deduplicate links.
  """

  @type source :: :generic | :youtube | :instagram | :x

  @schemes ~w(http https)
  @default_ports %{"http" => 80, "https" => 443}

  @x_hosts ~w(twitter.com www.twitter.com mobile.twitter.com x.com www.x.com mobile.x.com)
  @youtube_hosts ~w(youtube.com www.youtube.com m.youtube.com)
  @youtube_short_host "youtu.be"
  @youtube_canonical_host "www.youtube.com"
  # Kept as is by `normalize/1`, but captured by the YouTube extractor.
  @youtube_music_host "music.youtube.com"
  @instagram_hosts ~w(instagram.com www.instagram.com)
  @instagram_canonical_host "www.instagram.com"

  @tracking_params ~w(fbclid gclid dclid mc_cid mc_eid igsh igshid si ref_src ref_url)
  @tracking_prefixes ["utm_"]
  @x_tracking_params ~w(s t)
  @youtube_tracking_params ~w(feature pp)

  @host_pattern ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\z/
  @scheme_without_slashes ~r/\A[a-z][a-z0-9+.\-]*:(?!\d)/i

  @max_extracted 50
  # A URL starts at `http(s)://` or `www.` that doesn't continue a word, a
  # host, an email or another scheme, and runs until whitespace or a character
  # URLs don't carry unescaped (`<url>` and `[text](url)` end there).
  @candidate ~r/(?<![\w.@\/:\-])(?:https?:\/\/|www\.)[^\s<>"`\[\]{}|\\^]+/iu
  # Two URLs joined by a comma, as in `a,b`.
  @joined ~r/,(?=https?:\/\/|www\.)/i
  @trailing_punctuation ~w(. , ; : ! ? ' " * ” ’ »)
  @doc """
  Returns the canonical form of `input`, or `{:error, :invalid_url}`.
  """
  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, :invalid_url}
  def normalize(input) when is_binary(input) do
    with {:ok, %URI{} = uri} <- parse(String.trim(input)) do
      {:ok, uri |> canonicalize() |> build()}
    end
  end

  @doc """
  Detects the source of a canonical URL.
  """
  @spec source(String.t()) :: source()
  def source(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: @youtube_canonical_host} -> :youtube
      %URI{host: @youtube_music_host} -> :youtube
      %URI{host: @instagram_canonical_host} -> :instagram
      %URI{host: "x.com"} -> :x
      _ -> :generic
    end
  end

  @doc """
  Returns every URL in `text`, as written, in order of appearance: those
  starting with `http://`, `https://` or `www.`, separated by whitespace,
  commas or the markup around them (`<url>`, `[text](url)`, quotes).

  Trailing punctuation is not part of a URL, except a closing parenthesis
  that balances one inside it, as in Wikipedia's. URLs with the same
  canonical form (see `normalize/1`) appear once; ones that don't normalize
  are kept, so the caller can count them as invalid. At most #{@max_extracted}
  are returned.
  """
  @spec extract_all(String.t()) :: [String.t()]
  def extract_all(text) when is_binary(text) do
    @candidate
    |> Regex.scan(text)
    |> Stream.flat_map(fn [match] -> Regex.split(@joined, match) end)
    |> Stream.map(&trim_trailing/1)
    |> Stream.reject(&bare_prefix?/1)
    |> Stream.uniq_by(&dedupe_key/1)
    |> Enum.take(@max_extracted)
  end

  defp trim_trailing(url) do
    last = String.last(url)

    if last in @trailing_punctuation or (last == ")" and unbalanced_parenthesis?(url)),
      do: url |> drop_last() |> trim_trailing(),
      else: url
  end

  defp unbalanced_parenthesis?(url), do: count(url, ")") > count(url, "(")

  defp count(url, char), do: url |> :binary.matches(char) |> length()

  defp drop_last(url), do: String.slice(url, 0..-2//1)

  defp bare_prefix?(url), do: String.downcase(url) in ["http://", "https://", "www."]

  defp dedupe_key(url) do
    case normalize(url) do
      {:ok, canonical} -> canonical
      {:error, :invalid_url} -> url
    end
  end

  defp parse(""), do: {:error, :invalid_url}

  defp parse(trimmed) do
    cond do
      String.contains?(trimmed, "://") -> validate(URI.parse(trimmed))
      Regex.match?(@scheme_without_slashes, trimmed) -> {:error, :invalid_url}
      true -> validate(URI.parse("https://" <> trimmed))
    end
  end

  defp validate(%URI{scheme: scheme, host: host} = uri) when is_binary(scheme) and is_binary(host) do
    scheme = String.downcase(scheme)
    host = String.downcase(host)

    if scheme in @schemes and valid_host?(host) do
      {:ok, %{uri | scheme: scheme, host: host}}
    else
      {:error, :invalid_url}
    end
  end

  defp validate(%URI{}), do: {:error, :invalid_url}

  defp valid_host?("localhost"), do: true
  defp valid_host?(host), do: String.contains?(host, ".") and Regex.match?(@host_pattern, host)

  defp canonicalize(%URI{host: host} = uri) do
    uri = %{uri | fragment: nil, userinfo: nil, port: effective_port(uri)}
    segments = path_segments(uri.path)

    cond do
      host in @x_hosts -> clean(%{uri | scheme: "https", host: "x.com", port: 443}, @x_tracking_params)
      host in @instagram_hosts -> instagram(uri)
      host == @youtube_short_host -> youtube_short(uri, segments)
      host in @youtube_hosts -> youtube(uri, segments)
      true -> clean(uri, [])
    end
  end

  defp instagram(uri) do
    clean(%{uri | scheme: "https", host: @instagram_canonical_host, port: 443, query: nil}, [])
  end

  defp youtube_short(uri, [id | _]), do: youtube_watch(uri, id)
  defp youtube_short(uri, []), do: clean(youtube_base(uri), @youtube_tracking_params)

  defp youtube(uri, ["shorts", id | _]), do: youtube_watch(uri, id)

  defp youtube(%URI{path: "/watch"} = uri, _segments) do
    case uri.query |> query_pairs() |> Enum.find(&(key(&1) == "v")) do
      "v=" <> id when id != "" -> youtube_watch(uri, id)
      _ -> clean(%{youtube_base(uri) | query: nil}, [])
    end
  end

  defp youtube(uri, _segments), do: clean(youtube_base(uri), @youtube_tracking_params)

  defp youtube_watch(uri, id) do
    %{youtube_base(uri) | path: "/watch", query: "v=" <> id}
  end

  defp youtube_base(uri), do: %{uri | scheme: "https", host: @youtube_canonical_host, port: 443}

  # Drops tracking params (and any in `extra`), keeping the rest in order.
  defp clean(%URI{} = uri, extra) do
    query =
      uri.query
      |> query_pairs()
      |> Enum.reject(&tracking?(key(&1), extra))
      |> Enum.join("&")

    %{uri | query: if(query == "", do: nil, else: query), path: clean_path(uri.path)}
  end

  defp tracking?(key, extra) do
    key in @tracking_params or key in extra or Enum.any?(@tracking_prefixes, &String.starts_with?(key, &1))
  end

  defp query_pairs(nil), do: []
  defp query_pairs(query), do: String.split(query, "&", trim: true)

  defp key(pair), do: pair |> String.split("=", parts: 2) |> hd() |> URI.decode_www_form()

  defp path_segments(nil), do: []
  defp path_segments(path), do: String.split(path, "/", trim: true)

  defp clean_path(path) when path in [nil, "", "/"], do: "/"
  defp clean_path(path), do: path |> String.trim_trailing("/") |> then(&if(&1 == "", do: "/", else: &1))

  defp effective_port(%URI{scheme: scheme, port: port}) do
    if port == @default_ports[String.downcase(scheme)], do: nil, else: port
  end

  defp build(%URI{} = uri) do
    uri = %{uri | port: if(uri.port == @default_ports[uri.scheme], do: nil, else: uri.port)}
    URI.to_string(uri)
  end
end
