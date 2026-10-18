defmodule Acervo.Library.Extractor do
  @moduledoc """
  Turns a URL into a `Acervo.Library.Capture`.

  Source-specific extractors implement this behaviour; `for/1` picks the first
  that matches the URL and falls back to the generic HTML extractor.
  """

  alias Acervo.Library.Capture
  alias Acervo.Library.Extractors.Generic
  alias Acervo.Library.Extractors.Instagram
  alias Acervo.Library.Extractors.X
  alias Acervo.Library.Extractors.YouTube

  @type error :: :blocked | :not_found | :timeout | {:http, integer()} | term()

  @callback match?(URI.t()) :: boolean()
  @callback extract(URI.t()) :: {:ok, Capture.t()} | {:error, error()}

  @extractors [YouTube, X, Instagram]

  @doc "Returns the extractor module for `uri`."
  @spec for(URI.t()) :: module()
  def for(%URI{} = uri), do: Enum.find(@extractors, Generic, & &1.match?(uri))

  @doc "Extracts a preview from `url`, dispatching to the matching extractor."
  @spec extract(String.t()) :: {:ok, Capture.t()} | {:error, error()}
  def extract(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, uri} -> __MODULE__.for(uri).extract(uri)
      {:error, _} -> {:error, :invalid_url}
    end
  end
end
