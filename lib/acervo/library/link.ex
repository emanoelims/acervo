defmodule Acervo.Library.Link do
  @moduledoc false
  use Acervo.Schema

  import Ecto.Changeset

  alias Acervo.Accounts.User
  alias Acervo.Collections.Collection
  alias Acervo.Collections.CollectionLink
  alias Acervo.Collections.Suggestion
  alias Acervo.Library.LinkImage

  schema "links" do
    field :url, :string
    field :canonical_url, :string
    field :resolved_url, :string
    field :source, Ecto.Enum, values: [:generic, :youtube, :instagram, :x]
    field :status, Ecto.Enum, values: [:pending, :processing, :ready, :failed], default: :pending
    field :capture_error, :string
    field :title, :string
    field :description, :string
    field :author, :string
    field :site_name, :string
    field :published_at, :utc_datetime
    field :text_excerpt, :string
    field :embeddable, :boolean
    # Up to 300 KB, so it is only loaded when asked for (`Library.reader_content/2`).
    field :content_html, :string, load_in_query: false
    field :content_source, Ecto.Enum, values: [:markdown, :html]
    field :content_extracted_at, :utc_datetime
    field :note, :string
    field :triaged_at, :utc_datetime
    field :image_description, :string
    field :image_description_edited_at, :utc_datetime
    field :language, :string
    field :enrichment_status, Ecto.Enum, values: [:pending, :ready, :failed]
    field :enriched_at, :utc_datetime
    # The search embedding (4 KB) and its digest are only loaded when asked
    # for. `search_tsv` is a generated column, left out so Ecto never writes it.
    field :embedding, Pgvector.Ecto.Vector, load_in_query: false
    field :embedding_model, :string
    field :embedding_digest, :binary, load_in_query: false
    field :embedding_status, Ecto.Enum, values: [:pending, :ready, :failed]
    field :embedded_at, :utc_datetime

    belongs_to :user, User
    has_many :images, LinkImage, preload_order: [asc: :position]
    many_to_many :collections, Collection, join_through: CollectionLink
    has_many :suggestions, Suggestion

    timestamps()
  end

  def create_changeset(link, attrs) do
    link
    |> cast(attrs, [:url, :canonical_url, :source])
    |> validate_required([:url, :canonical_url, :source])
    |> validate_length(:url, max: 2048)
    |> validate_length(:canonical_url, max: 2048)
    |> unique_constraint(:canonical_url, name: :links_user_id_canonical_url_index)
  end

  @truncations [title: 500, description: 2000, author: 200, site_name: 200, capture_error: 200, text_excerpt: 8000]

  def capture_changeset(link, attrs) do
    attrs = truncate_captured(attrs)

    link
    |> cast(attrs, [
      :title,
      :description,
      :author,
      :site_name,
      :published_at,
      :text_excerpt,
      :status,
      :capture_error,
      :resolved_url,
      :embeddable
    ])
    |> validate_length(:text_excerpt, max: 8000)
    |> validate_length(:resolved_url, max: 2048)
  end

  defp truncate_captured(attrs) do
    Map.new(attrs, fn {key, value} -> {key, truncate(key, value)} end)
  end

  defp truncate(key, value) when is_binary(value) do
    case List.keyfind(@truncations, to_existing_key(key), 0) do
      {_, max} -> String.slice(value, 0, max)
      nil -> value
    end
  end

  defp truncate(_key, value), do: value

  defp to_existing_key(key) when is_atom(key), do: key

  defp to_existing_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  @doc """
  The reader content, the trusted output of `Acervo.Library.Sanitizer`.
  """
  def content_changeset(link, attrs) do
    link
    |> cast(attrs, [:content_html, :content_source, :content_extracted_at])
    |> validate_length(:content_html, max: 320_000, count: :bytes)
  end

  def note_changeset(link, attrs) do
    link
    |> cast(attrs, [:note])
    |> validate_length(:note, max: 4000)
  end

  @language ~r/\A[a-z]{2,3}(-[A-Za-z]{2,4})?\z/

  @doc """
  The AI enrichment: the image description, the page's language and the
  enrichment's state. The description is clipped to 1000 characters and the
  language to 16, and NUL bytes are stripped. The language must be a BCP 47
  style tag such as `"pt"` or `"pt-BR"`.
  """
  def enrichment_changeset(link, attrs) do
    link
    |> cast(attrs, [:image_description, :language, :enrichment_status, :enriched_at, :image_description_edited_at])
    |> update_change(:image_description, &clip(&1, 1000))
    |> update_change(:language, &clip(&1, 16))
    |> validate_format(:language, @language)
  end

  @doc """
  The owner's edit of the image description: trimmed, blank becomes nil, at
  most 1000 characters. Stamps `image_description_edited_at` when it changes.
  """
  def image_description_changeset(link, attrs) do
    link
    |> cast(attrs, [:image_description], empty_values: [])
    |> update_change(:image_description, &blank_to_nil/1)
    |> validate_length(:image_description, max: 1000)
    |> stamp_edited_at()
  end

  defp stamp_edited_at(changeset) do
    if changed?(changeset, :image_description) do
      put_change(changeset, :image_description_edited_at, DateTime.utc_now(:second))
    else
      changeset
    end
  end

  @doc """
  The search embedding: the vector, the model that made it, the digest of
  the embedded text and the embedding's state.
  """
  def embedding_changeset(link, attrs) do
    link
    |> cast(attrs, [:embedding, :embedding_model, :embedding_digest, :embedding_status, :embedded_at])
    |> validate_length(:embedding_model, max: 200)
  end

  defp clip(value, max) when is_binary(value), do: value |> String.replace(<<0>>, "") |> String.slice(0, max)
  defp clip(value, _max), do: value

  defp blank_to_nil(value) when is_binary(value) do
    case value |> String.replace(<<0>>, "") |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
