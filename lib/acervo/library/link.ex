defmodule Acervo.Library.Link do
  @moduledoc false
  use Acervo.Schema

  import Ecto.Changeset

  alias Acervo.Accounts.User
  alias Acervo.Collections.Collection
  alias Acervo.Collections.CollectionLink
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

    belongs_to :user, User
    has_many :images, LinkImage, preload_order: [asc: :position]
    many_to_many :collections, Collection, join_through: CollectionLink

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
end
