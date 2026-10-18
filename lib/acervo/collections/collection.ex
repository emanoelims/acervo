defmodule Acervo.Collections.Collection do
  @moduledoc false
  use Acervo.Schema
  use Gettext, backend: AcervoWeb.Gettext

  import Ecto.Changeset

  alias Acervo.Accounts.User
  alias Acervo.Collections.CollectionLink
  alias Acervo.Library.Link

  schema "collections" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :position, :integer, default: 0
    field :link_count, :integer, virtual: true
    field :cover_image_ids, {:array, :binary_id}, virtual: true

    belongs_to :user, User
    many_to_many :links, Link, join_through: CollectionLink

    timestamps()
  end

  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [:name, :description, :position])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:description, max: 280)
    |> put_slug()
    |> unique_constraint(:name, name: :collections_user_id_slug_index)
  end

  @doc """
  Turns a name into a URL slug: lowercase, accents removed, runs of
  non-alphanumerics collapsed to a single dash. Returns `""` when nothing is left.
  """
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp put_slug(changeset) do
    case fetch_change(changeset, :name) do
      {:ok, name} when is_binary(name) ->
        case slugify(name) do
          "" -> add_error(changeset, :name, dgettext_noop("errors", "must contain letters or numbers"))
          slug -> put_change(changeset, :slug, slug)
        end

      _ ->
        changeset
    end
  end
end
