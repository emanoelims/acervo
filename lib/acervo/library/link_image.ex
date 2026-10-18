defmodule Acervo.Library.LinkImage do
  @moduledoc false
  use Acervo.Schema

  alias Acervo.Library.Link

  schema "link_images" do
    field :position, :integer, default: 0
    field :kind, Ecto.Enum, values: [:preview, :screenshot]
    field :content_type, :string
    field :bytes, :binary
    field :width, :integer
    field :height, :integer
    field :sha256, :string

    belongs_to :link, Link

    timestamps()
  end
end
