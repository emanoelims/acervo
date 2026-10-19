defmodule Acervo.Library.LinkImage do
  @moduledoc """
  A captured image, stored as WebP. Card images (`card_kinds/0`) illustrate
  the link's card, by `position`: `:preview` images come from the page,
  `:screenshot` images from the user and `:snapshot` images from the
  screenshot service (`Acervo.Library.CaptureSnapshot`). `:content` images
  belong to the reader view's article, which links them by id, and never
  show on cards.
  """
  use Acervo.Schema

  import Ecto.Changeset

  alias Acervo.Library.Link

  schema "link_images" do
    field :position, :integer, default: 0
    field :kind, Ecto.Enum, values: [:preview, :screenshot, :snapshot, :content]
    field :content_type, :string
    field :bytes, :binary
    field :width, :integer
    field :height, :integer
    field :sha256, :string

    belongs_to :link, Link

    timestamps()
  end

  @card_kinds [:preview, :screenshot, :snapshot]

  @doc "The kinds of image that illustrate a link's card."
  @spec card_kinds() :: [atom()]
  def card_kinds, do: @card_kinds

  def changeset(image, attrs) do
    image
    |> cast(attrs, [:position, :kind, :content_type, :bytes, :width, :height, :sha256])
    |> validate_required([:kind, :content_type, :bytes, :width, :height, :sha256])
    |> validate_inclusion(:content_type, ["image/webp"])
    |> validate_length(:sha256, is: 64)
  end
end
