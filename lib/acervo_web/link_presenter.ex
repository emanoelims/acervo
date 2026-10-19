defmodule AcervoWeb.LinkPresenter do
  @moduledoc """
  What a link shows, decided outside the markup: its title, host and meta
  line, which kind of card it gets, where its images load from, how its
  captured text breaks into paragraphs and which collections the picker
  offers. Pure functions over links (`Acervo.Library.Link` or any map with
  the same fields), tested on their own.
  """
  use AcervoWeb, :verified_routes

  alias Acervo.Collections
  alias AcervoWeb.Format

  @paragraph_chars 480

  @doc """
  The link's title, falling back to its host while there is none.

      iex> AcervoWeb.LinkPresenter.display_title(%{title: "", canonical_url: "https://www.example.com/a"})
      "example.com"
  """
  def display_title(%{title: title}) when is_binary(title) and title != "", do: title
  def display_title(link), do: host(link)

  @doc "The link's site name, falling back to its title."
  def site_title(%{site_name: name}) when is_binary(name) and name != "", do: name
  def site_title(link), do: display_title(link)

  @doc """
  The link's host without a leading `www.`, or the URL itself without a host.

      iex> AcervoWeb.LinkPresenter.host(%{canonical_url: "https://www.youtube.com/watch?v=1"})
      "youtube.com"
  """
  def host(%{canonical_url: url}) do
    case URI.parse(url) do
      %URI{host: "www." <> host} -> host
      %URI{host: host} when is_binary(host) -> host
      _ -> url
    end
  end

  @doc "When the link was published, or saved when that is unknown."
  def link_date(%{published_at: nil, inserted_at: inserted_at}), do: inserted_at
  def link_date(%{published_at: published_at}), do: published_at

  @doc """
  The card a link gets: a skeleton while it is captured, text without images,
  a 16:9 thumbnail for YouTube, or its image.
  """
  def kind(%{status: status}) when status in [:pending, :processing], do: :pending
  def kind(%{images: []}), do: :text
  def kind(%{source: :youtube}), do: :video
  def kind(_link), do: :image

  @doc "The link's first image, or nil."
  def first_image(%{images: [image | _]}), do: image
  def first_image(_link), do: nil

  @doc """
  Where an image loads from: `/images/:id`, scoped to its owner. An image
  that carries its own `src` (the styleguide's examples) uses that instead.

      iex> AcervoWeb.LinkPresenter.image_src(%{id: 7})
      "/images/7"
      iex> AcervoWeb.LinkPresenter.image_src(%{id: 7, src: "data:image/png;base64,"})
      "data:image/png;base64,"
  """
  def image_src(%{src: src}) when is_binary(src), do: src
  def image_src(%{id: id}), do: ~p"/images/#{id}"

  @doc "The link column's meta line: author, site and date, the blanks left out."
  def meta(link) do
    [link.author, link.site_name || host(link), Format.date(link_date(link))]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  @doc "A suggestion's name: its collection's, or the new name it proposes."
  def suggestion_name(%{collection: %{name: name}}), do: name
  def suggestion_name(%{proposed_name: name}), do: name

  @doc """
  Captured text is a single run, so it is cut into paragraphs between
  sentences, each about #{@paragraph_chars} characters long. Line breaks, if
  any, win.

      iex> AcervoWeb.LinkPresenter.paragraphs("One. Two.\\nThree.")
      ["One. Two.", "Three."]
  """
  def paragraphs(text) do
    text
    |> String.split(~r/\R+/u, trim: true)
    |> Enum.flat_map(&group_sentences/1)
  end

  defp group_sentences(text) do
    ~r/(?<=[.!?…])\s+(?=\S)/u
    |> Regex.split(String.trim(text), trim: true)
    |> Enum.chunk_while(
      "",
      fn
        sentence, "" -> {:cont, sentence}
        sentence, acc when byte_size(acc) < @paragraph_chars -> {:cont, acc <> " " <> sentence}
        sentence, acc -> {:cont, acc, sentence}
      end,
      fn
        "" -> {:cont, ""}
        acc -> {:cont, acc, ""}
      end
    )
  end

  @doc """
  What the "add to collection" picker lists for a query: the collections
  whose name contains it (accents and case ignored), plus the one whose slug
  it would take ("C++" matches no name but would take the slug of "C"), and
  whether it offers to create the query as a new collection.
  """
  def collection_choices(collections, query) do
    query = query || ""
    trimmed = String.trim(query)
    existing = Collections.find_by_name_or_slug(collections, query)
    matches = Enum.filter(collections, &String.contains?(fold(&1.name), fold(query)))

    options =
      if existing && trimmed != "" && existing not in matches, do: matches ++ [existing], else: matches

    %{query: trimmed, options: options, create?: trimmed != "" and is_nil(existing)}
  end

  defp fold(text) do
    text
    |> String.trim()
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
  end
end
