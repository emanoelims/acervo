defmodule Acervo.Search.Document do
  @moduledoc """
  The text embedded for a link's search vector (`Acervo.Search.EmbedLink`).

  One labelled line per present field, highest signal first, so truncation
  only drops the tail of the article:

      Title: …
      Site: …          (site_name, else the host of the link's URL)
      Author: …
      Collections: …   (the scope's collections holding the link, by name)
      Description: …
      Image: …         (image_description)
      Note: …
      Text: …          (the article text)

  The article text is capped at 6,000 characters and the whole document
  at 8,000, both cut at a whitespace boundary. At the usual heuristic of 4
  characters per token (Portuguese runs nearer 3.5) that is about 2,000
  tokens, 1/16 of the embedding model's 32k context.

  Every field is cleaned like enrichment input: invalid UTF-8, NUL and
  control characters are stripped (newlines kept) and whitespace is
  collapsed. The content comes from the web and is untrusted. An embedding
  model follows no instructions, so it needs no framing, but it is never
  logged.
  """

  import Ecto.Query

  alias Acervo.Accounts.Scope
  alias Acervo.AI.Enrichment
  alias Acervo.Collections.Collection
  alias Acervo.Collections.CollectionLink
  alias Acervo.Library
  alias Acervo.Library.Link
  alias Acervo.Repo

  @max_text 6_000
  @max_document 8_000

  @doc """
  Builds the document for one of the scope's links, or `:skip` when its
  title, description, image description, note and article text are all
  blank: there is nothing worth embedding.
  """
  @spec build(Scope.t(), Link.t()) :: {:ok, String.t()} | :skip
  def build(%Scope{} = scope, %Link{} = link) do
    text = Enrichment.article_text(Library.reader_content(scope, link), link.text_excerpt, @max_text)
    title = clean(link.title)
    description = clean(link.description)
    image = clean(link.image_description)
    note = clean(link.note)

    if Enum.all?([title, description, image, note, text], &(&1 == "")) do
      :skip
    else
      document =
        [
          {"Title", title},
          {"Site", site(link)},
          {"Author", clean(link.author)},
          {"Collections", collections(scope, link)},
          {"Description", description},
          {"Image", image},
          {"Note", note},
          {"Text", text}
        ]
        |> Enum.reject(fn {_label, value} -> value == "" end)
        |> Enum.map_join("\n", fn {label, value} -> "#{label}: #{value}" end)
        |> Enrichment.cap(@max_document)

      {:ok, document}
    end
  end

  @doc """
  The digest stored with an embedding: SHA-256 over the model and the
  document. A link whose digest is unchanged needs no new call.
  """
  @spec digest(String.t(), String.t()) :: binary()
  def digest(model, text) when is_binary(model) and is_binary(text), do: :crypto.hash(:sha256, [model, 0, text])

  defp clean(nil), do: ""
  defp clean(value) when is_binary(value), do: Enrichment.clean_text(value)

  defp site(%Link{site_name: site_name} = link) do
    case clean(site_name) do
      "" -> host(link.resolved_url || link.canonical_url)
      site -> site
    end
  end

  defp host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> clean(host)
      _ -> ""
    end
  end

  defp host(nil), do: ""

  # Sorted, so the same memberships always build the same document.
  defp collections(%Scope{user: user}, %Link{id: link_id}) do
    from(c in Collection,
      join: cl in CollectionLink,
      on: cl.collection_id == c.id,
      where: cl.link_id == ^link_id and c.user_id == ^user.id,
      order_by: [asc: c.name, asc: c.id],
      select: c.name
    )
    |> Repo.all()
    |> Enum.map(&clean/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end
end
