defmodule Acervo.Collections.CollectionLink do
  @moduledoc false
  use Acervo.Schema

  alias Acervo.Collections.Collection
  alias Acervo.Library.Link

  schema "collection_links" do
    field :source, Ecto.Enum, values: [:manual, :suggestion], default: :manual

    belongs_to :collection, Collection
    belongs_to :link, Link

    timestamps(updated_at: false)
  end
end
